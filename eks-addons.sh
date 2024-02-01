#!/bin/bash

jsonname="addons.json"
aws eks describe-addon-versions > "${jsonname}"
cat "${jsonname}" | jq '.addons[] | .addonName + "  " + "-----" + "  " + .addonVersions[].addonVersion' > eks-addons.txt
sort -u eks-addons.txt -o eks-addons.txt