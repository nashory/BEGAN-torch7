-- Training parameter settings.
require 'nn'
require 'torch'
require 'optim'

local M = { }

function M.parse(arg)
	local cmd = torch.CmdLine()
	cmd:text()
	cmd:text('Training code.')
	cmd:text()
	cmd:text('Input arguments')


	-------------- Frequently Changed options -----------
	cmd:option('-gpuid', 0, 'which gpu to use. -1 = use CPU')
	cmd:option('-name', 'CelebA_dcgan', 'experiments numbering.')
	cmd:option('-snapshot_every', 1, 'will save models every N epoch.')
	cmd:option('-loadSize', 80, 'resize the loaded image to load size maintatining aspect ratio.')
	cmd:option('-sampleSize', 64, 'size of random crops')
    cmd:option('-gamma', 0.5, 'gamma factor of BEGAN')


	---------------- General options ---------------
	cmd:option('-seed', 0, 'random number generator seed to use (0 means random seed)')
	cmd:option('-backend', 'cudnn', 'cudnn option.')


	---------------- Data loading options ---------------
	cmd:option('-data_root_train', '/home1/work/nashory/data/CelebA/Img')
	cmd:option('-nthreads', 8, '# of workers to use for data loading.')
	cmd:option('-display', true, 'true : display server on / false : display server off')
	cmd:option('-display_id', 10, 'display window id.')
	cmd:option('-display_iter', 10, '# of iterations after which display is updated.')
	cmd:option('-display_server_ip', '10.64.81.227', 'host server ip address.')
	cmd:option('-display_server_port', 8000, 'host server port.')
	cmd:option('-sever_name', 'dcgan-test', 'server name.')


	-------------- Training options---------------
	cmd:option('-batchSize', 64, 'batch size for training')
	cmd:option('-lr', 0.0002, 'learning rate')
	cmd:option('-noisetype', 'uniform', 'uniform/normal distribution noise.')

	-- ndims of output features
	cmd:option('-ngf', 64, 'output dimension of first conv layer of generator.')
	cmd:option('-ndf', 64, 'output dimension of first conv layer of discriminator.')
	cmd:option('-nc', 3, 'input image channel. (rgb:3, gray:1)')
	cmd:option('-nh', 512, '# of dimension for input noise(h)')
	cmd:text()

	-- return opt.
	local opt = cmd:parse(arg or {})
	return opt
end

return M


