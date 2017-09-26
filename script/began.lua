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
    self.thres = 0.02
    
    -- generate test_noise(fixed)
    self.test_noise = torch.Tensor(64, self.nh, 1, 1)
    if self.noisetype == 'uniform' then self.test_noise:uniform(-1,1)
    elseif self.noisetype == 'normal' then self.test_noise:normal(0,1) end
    
    if opt.display then
        self.disp = require 'display'
        self.disp.configure({hostname=opt.display_server_ip, port=opt.display_server_port})
    end

    -- get models and criterion.
    self.gen = model[1]:cuda()
    self.dis = model[2]:cuda()
    self.dis2 = self.dis:clone()
    self.crit_adv = criterion[1]:cuda()
end

BEGAN['fDx'] = function(self, x)
    self.dis:zeroGradParameters()
    
    -- generate noise(z_D)
    if self.noisetype == 'uniform' then self.noise:uniform(-1,1)
    elseif self.noisetype == 'normal' then self.noise:normal(0,1) end
    
    -- train with real(x)
    self.x = self.dataset:getBatch()
    self.x_ae = self.dis:forward(self.x:cuda()):clone()
    self.errD_real = self.crit_adv:forward(self.x:cuda(), self.x_ae:cuda())
    local d_errD_real = self.crit_adv:backward(self.x:cuda(), self.x_ae:cuda()):clone()
    local d_x_ae = self.dis:backward(self.x:cuda(), d_errD_real:mul(-1):cuda()):clone()

    -- train with fake(x_tilde)
    self.z = self.noise:clone():cuda()
    self.x_tilde = self.gen:forward(self.z):clone()
    self.x_tilde_ae = self.dis:forward(self.x_tilde):clone()
    self.errD_fake = self.crit_adv:forward(self.x_tilde:cuda(), self.x_tilde_ae:cuda())
    local d_errD_fake = self.crit_adv:backward(self.x_tilde:cuda(), self.x_tilde_ae:cuda()):clone()
    local d_x_tilde_ae = self.dis:backward(self.x_tilde:cuda(), d_errD_fake:mul(1*self.kt):cuda()):clone()

    -- return error.
    local errD = {real=self.errD_real, fake=self.errD_fake}
    return errD
end


BEGAN['fGx'] = function(self, x)
    self.gen:zeroGradParameters()
    
    local errG = self.crit_adv:forward(self.x_tilde:cuda(), self.x_tilde_ae:cuda())
    local d_errG = self.crit_adv:backward(self.x_tilde:cuda(), self.x_tilde_ae:cuda()):clone()
    local d_gen_dis = self.dis:updateGradInput(self.x_tilde:cuda(), d_errG:mul(-1):cuda()):clone()
    local d_gen_dummy = self.gen:backward(self.z:cuda(), d_gen_dis:cuda()):clone()

    -- closed loop control for kt
    self.kt = self.kt - self.lambda*(self.gamma*self.errD_real - errG)
    if self.kt > self.thres then self.kt = self.thres
    elseif self.kt < 0 then self.kt = 0 end


    -- Convergence measure
    self.measure = self.errD_real + math.abs(self.gamma*self.errD_real - errG)
    
    return errG
end


function BEGAN:train(epoch, loader)
    -- Initialize data variables.
    self.noise = torch.Tensor(self.batchSize, self.nh, 1, 1)

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

            -- weight update.
            optimizer.dis.method(self.param_dis, self.gradParam_dis, optimizer.dis.config.lr,
                                optimizer.dis.config.beta1, optimizer.dis.config.beta2,
                                optimizer.dis.config.elipson, optimizer.dis.optimstate)
            local err_gen = self:fGx()
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
                local x_test = self.gen:forward(self.test_noise:cuda()):clone()
                for i = 1, 8 do
                    for j =  1, 8 do
                        im_png[{{},{self.sampleSize*(j-1)+1, self.sampleSize*(j)},{self.sampleSize*(i-1)+1, self.sampleSize*(i)}}]:copy(x_test[{{8*(i-1)+j},{},{},{}}]:clone():add(1):div(2))
                    end
                end
                os.execute('mkdir -p repo/image')
                image.save(string.format('repo/image/%d.jpg', totalIter/self.opt.display_iter), im_png)
            end

            -- logging
            local log_msg = string.format('Epoch: [%d][%6d/%6d]  Loss_D(real): %.4f | Loss_D(fake): %.4f | Loss_G: %.4f | kt: %.6f | Convergence: %.4f', e, iter, iter_per_epoch, err_dis.real, err_dis.fake, err_gen, self.kt, self.measure)
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




