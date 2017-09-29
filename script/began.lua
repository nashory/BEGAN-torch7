-- For training loop and learning rate scheduling.
-- BEGAN.
-- last modified : 2017.09.22, nashory
-- notation :   x --> real data (x)
--              x_tilde --> fake data (G(z))
--              x_ae --> auto-encoder output of x
--              x_tilde_ae --> auto-encoder output of x_tilde




require 'sys'
require 'optim'
require 'image'
require 'math'
local optimizer = require 'script.optimizer'


local BEGAN = torch.class('BEGAN')


function BEGAN:__init(model, criterion, opt, optimstate)
    self.model = model
    self.criterion = criterion
    self.optimstate = optimstate or {
        lr = opt.lr,
    }
    self.opt = opt
    self.noisetype = opt.noisetype
    self.nc = opt.nc
    self.nh = opt.nh
    self.gamma = opt.gamma
    self.lambda = opt.lambda
    self.kt = 0         -- initialize same with the paper.
    self.batchSize = opt.batchSize
    self.sampleSize = opt.sampleSize
    self.thres = 1.0
    
    -- generate test_noise(fixed)
    self.test_noise = torch.Tensor(64, self.nh)
    if self.noisetype == 'uniform' then self.test_noise:uniform(-1,1)
    elseif self.noisetype == 'normal' then self.test_noise:normal(0,1) end
    
    if opt.display then
        self.disp = require 'display'
        self.disp.configure({hostname=opt.display_server_ip, port=opt.display_server_port})
    end

    -- get models and criterion.
    self.gen = model[1]:cuda()
    self.dis = model[2]:cuda()
    self.crit_adv = criterion[1]:cuda()
end

BEGAN['fDx'] = function(self, x)
    self.dis:zeroGradParameters()
    
    -- generate noise(z_D)
    if self.noisetype == 'uniform' then self.noise:uniform(-1,1)
    elseif self.noisetype == 'normal' then self.noise:normal(0,1) end
   
    -- train with real(x)
    self.x = self.dataset:getBatch()
    self.dis:forward(self.x:cuda())
    self.x_ae = self.dis.output:clone()
    self.errD_real = self.crit_adv:forward(self.x_ae:cuda(), self.x:cuda())
    local d_errD_real = self.crit_adv:backward(self.x_ae:cuda(), self.x:cuda()):clone()
    local d_x_ae = self.dis:backward(self.x:cuda(), d_errD_real:cuda()):clone()
    
    -- train with fake(x_tilde)
    self.z = self.noise:clone():cuda()
    self.gen:forward(self.z)
    self.x_tilde = self.gen.output:clone()
    self.dis:forward(self.x_tilde)
    self.x_tilde_ae = self.dis.output:clone()
    self.errD_fake = self.crit_adv:forward(self.x_tilde_ae:cuda(), self.x_tilde:cuda())
    local d_errD_fake = self.crit_adv:backward(self.x_tilde_ae:cuda(), self.x_tilde:cuda()):clone()
    local d_x_tilde_ae = self.dis:backward(self.x_tilde:cuda(), d_errD_fake:mul(-self.kt):cuda()):clone()
    
    
    -- return error.
    local errD = {real = self.errD_real, fake = self.errD_fake}
    return errD
end


BEGAN['fGx'] = function(self, x)
    self.gen:zeroGradParameters()
   
    -- generate noise(z_G)
    if self.noisetype == 'uniform' then self.noise:uniform(-1,1)
    elseif self.noisetype == 'normal' then self.noise:normal(0,1) end
    
    local z = self.noise:clone():cuda()
    self.gen:forward(z)
    local x_tilde = self.gen.output:clone()
    self.dis:forward(x_tilde)
    local x_tilde_ae = self.dis.output:clone()
    local errG = self.crit_adv:forward(x_tilde_ae:cuda(), x_tilde:cuda())
    
    local d_errG = self.crit_adv:updateGradInput(x_tilde_ae:cuda(), x_tilde:cuda()):clone()
    local d_gen_dis = self.dis:updateGradInput(x_tilde:cuda(), d_errG:cuda()):clone()
    local d_gen_dummy = self.gen:backward(z:cuda(), d_gen_dis:cuda()):clone()

    -- closed loop control for kt
    local delta = self.gamma*self.errD_real - errG
    self.kt = self.kt + self.lambda*(delta)

    if self.kt > self.thres then self.kt = self.thres
    elseif self.kt < 0 then self.kt = 0 end

    -- Convergence measure
    self.measure = self.errD_real + math.abs(delta)

    return {err = errG, delta = delta}
end


function BEGAN:train(epoch, loader)
    -- Initialize data variables.
    self.noise = torch.Tensor(self.batchSize, self.nh)

    -- get network weights.
    self.dataset = loader.new(self.opt.nthreads, self.opt)
    print(string.format('Dataset size :  %d', self.dataset:size()))
    self.gen:training()
    self.dis:training()
    self.param_gen, self.gradParam_gen = self.gen:getParameters()
    self.param_dis, self.gradParam_dis = self.dis:getParameters()


    local totalIter = 0
    for e = 1, epoch do
        -- get max iteration for 1 epcoh.
        local iter_per_epoch = math.ceil(self.dataset:size()/self.batchSize)
        for iter  = 1, iter_per_epoch do
            totalIter = totalIter + 1

            -- forward/backward and update weights with optimizer.
            -- DO NOT CHANGE OPTIMIZATION ORDER.
            local err_dis = self:fDx()
            local err_gen = self:fGx()

            -- weight update.
            optimizer.dis.method(self.param_dis, self.gradParam_dis, optimizer.dis.config.lr,
                                optimizer.dis.config.beta1, optimizer.dis.config.beta2,
                                optimizer.dis.config.elipson, optimizer.dis.optimstate)
            optimizer.gen.method(self.param_gen, self.gradParam_gen, optimizer.gen.config.lr,
                                optimizer.gen.config.beta1, optimizer.gen.config.beta2,
                                optimizer.gen.config.elipson, optimizer.gen.optimstate)

            -- save model at every specified epoch.
            local data = {dis = self.dis, gen = self.gen}
            self:snapshot(string.format('repo/%s', self.opt.name), self.opt.name, totalIter, data)

            -- display server.
            if (totalIter%self.opt.display_iter==0) and (self.opt.display) then
                local im_real = self.x:clone()
                local im_fake = self.x_tilde:clone()
                local im_real_ae = self.x_ae:clone()
                local im_fake_ae = self.x_tilde_ae:clone()
                
                self.disp.image(im_real, {win=self.opt.display_id + self.opt.gpuid, title=self.opt.server_name})
                self.disp.image(im_fake, {win=self.opt.display_id*2 + self.opt.gpuid, title=self.opt.server_name})
                self.disp.image(im_real_ae, {win=self.opt.display_id*4 + self.opt.gpuid, title=self.opt.server_name})
                self.disp.image(im_fake_ae, {win=self.opt.display_id*6 + self.opt.gpuid, title=self.opt.server_name})


                -- save image as png (size 64x64, grid 8x8 fixed).
                local im_png = torch.Tensor(3, self.sampleSize*8, self.sampleSize*8):zero()
                self.gen:forward(self.test_noise:cuda())
                local x_test = self.gen.output:clone()
                for i = 1, 8 do
                    for j =  1, 8 do
                        im_png[{{},{self.sampleSize*(j-1)+1, self.sampleSize*(j)},{self.sampleSize*(i-1)+1, self.sampleSize*(i)}}]:copy(x_test[{{8*(i-1)+j},{},{},{}}]:clone():add(1):div(2))
                    end
                end
                os.execute('mkdir -p repo/image')
                image.save(string.format('repo/image/%d.jpg', totalIter/self.opt.display_iter), im_png)
            end

            -- logging
            local log_msg = string.format('Epoch: [%d][%6d/%6d]  D(real): %.4f | D(fake): %.4f | G: %.4f | Delta: %.4f | kt: %.6f | Convergence: %.4f', e, iter, iter_per_epoch, err_dis.real, err_dis.fake, err_gen.err, err_gen.delta, self.kt, self.measure)
            print(log_msg)
        end
    end
end


function BEGAN:snapshot(path, fname, iter, data)
    -- if dir not exist, create it.
    if not paths.dirp(path) then    os.execute(string.format('mkdir -p %s', path)) end
    
    local fname = fname .. '_Iter' .. iter .. '.t7'
    local iter_per_epoch = math.ceil(self.dataset:size()/self.batchSize)
    if iter % math.ceil(self.opt.snapshot_every*iter_per_epoch) == 0 then
        local save_path = path .. '/' .. fname
        torch.save(save_path)
        print('[Snapshot]: saved model @ ' .. save_path)
    end
end


return BEGAN




