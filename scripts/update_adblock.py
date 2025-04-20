# Setup: clone https://github.com/adblockplus/abp2blocklist next to the repo

import requests, os, json

lists = {
    'easylist': 'https://easylist.to/easylist/easylist.txt',
    'easycookie': 'https://secure.fanboy.co.nz/fanboy-cookiemonster.txt'
}

for name, list in lists.items(): 
    # download to this dir (scripts)
    dl_path = './' + name + '.txt'
    with open(dl_path, 'wb') as f:
        response = requests.get(list)
        f.write(response.content)
    # convert to json format using node ../../abp2blocklist/abp2blocklist.js < input.txt > output.json

    destpath = f'../Wowser/Core/Sources/Core/Adblock/{name}.json'

    os.system(f'node ../../abp2blocklist/abp2blocklist.js < {dl_path} > {destpath}')

    # Now read destpath, minify, re-write as {name}.min.json, delete orig
    with open(destpath, 'r') as f:
        data = f.read()
    # minify
    data = json.dumps(json.loads(data), separators=(',', ':'))
    # write to {name}.min.json
    minpath = f'../Wowser/Core/Sources/Core/Adblock/{name}.min.json'
    with open(minpath, 'w') as f:
        f.write(data)
    # delete orig
    os.remove(destpath)
        
