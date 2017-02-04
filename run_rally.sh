#!/bin/bash
set -ex 
wget -q https://raw.githubusercontent.com/openstack/rally/master/install_rally.sh 
chmod +x install_rally.sh
./install_rally.sh -v -y
# Configure rally
cat > /tmp/rally.json <<RE_EOF
{
    "admin": {
        "project_domain_name": "default",
        "password": "openstack",
        "project_name": "admin",
        "user_domain_name": "default",
        "username": "admin"
    },
    "auth_url": "http://localhost:5000/v3/",
    "endpoint_type": "public",
    "https_cacert": "",
    "https_insecure": false,
    "type": "ExistingCloud"
}
RE_EOF

rally deployment create --filename /tmp/rally.json --name RALLYCI
rally deployment use RALLYCI
rally deployment check
# Run benchmarks
rally task start --abort-on-sla-failure /usr/share/rally/samples/tasks/scenarios/neutron/create-and-delete-networks.yaml
rally task report --junit --out output.xml
rally task report --out /var/www/html/output.html
