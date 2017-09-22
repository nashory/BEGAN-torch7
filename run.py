# python script to run GAN algorithms.

import os, sys
import json
import argparse

parser = argparse.ArgumentParser()

parser.add_argument('--type', default='began', help='BEGAN')
args = parser.parse_args()
params = vars(args)
print json.dumps(params, indent = 4)


gan_type = params['type']

if gan_type == 'began': os.system('th script/main.lua')
else:
    print('Error: wrong type arguments!')
    os.exit()


