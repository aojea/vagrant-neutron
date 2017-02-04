#!/bin/bash

set -ex 
export DEBIAN_FRONTEND=noninteractive

OS_VERSION=${1:-mitaka}
admin_token=openstack
IP=localhost
EXTIP=localhost

apt-get update
apt-get -y install software-properties-common ntp curl wget git crudini screen libfontconfig

echo 'hardstatus on' >> /home/vagrant/.screenrc
echo 'hardstatus alwayslastine' >> /home/vagrant/.screenrc
echo 'hardstatus string "%w"' >> /home/vagrant/.screenrc

if [ "$OS_VERSION" = "newton" ] ; then
 apt-get -y install ubuntu-cloud-keyring
 add-apt-repository -y cloud-archive:$OS_VERSION
 apt-get update
fi

# Disable apparmor
/etc/init.d/apparmor stop
update-rc.d -f apparmor remove

# Create openstack credentials
cat > admin.rc <<EOF
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=openstack
export OS_AUTH_URL=http://localhost:35357/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

#Install mysql
debconf-set-selections <<< 'mysql-server mysql-server/root_password password openstack'
debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password openstack'
apt-get -qq install mysql-server
systemctl start mysql

sed -i "s/bind-address.*/bind-address = 0.0.0.0/" /etc/mysql/my.cnf
sed -i 's/max_connections/\#max_connections/g' /etc/mysql/my.cnf
sed -i '/\[mysqld\]/a max_connections = 2500' /etc/mysql/my.cnf
# adding grant privileges to mysql root user from everywhere
# thx to http://stackoverflow.com/questions/7528967/how-to-grant-mysql-privileges-in-a-bash-script for this
MYSQL=`which mysql`
Q1="GRANT ALL ON *.* TO 'root'@'%' IDENTIFIED BY 'openstack' WITH GRANT OPTION;"
Q2="FLUSH PRIVILEGES;"
SQL="${Q1}${Q2}"
$MYSQL -uroot -popenstack -e "$SQL"

systemctl restart mysql

#Install Openstack client
apt-get -qq install python-openstackclient

#Install Keystone
echo "<<<<<Creating databases>>>>>"
mysql -uroot -popenstack <<EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost'  IDENTIFIED BY 'openstack';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%'  IDENTIFIED BY 'openstack';
CREATE DATABASE nova;
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY 'openstack';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY 'openstack';
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY 'openstack';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY 'openstack';
CREATE DATABASE neutron;
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY 'openstack';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY 'openstack';
CREATE DATABASE heat;
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' IDENTIFIED BY 'openstack';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' IDENTIFIED BY 'openstack';
exit
EOF
echo "Success!"
#Disable the keystone service from starting automatically after installation:
echo "manual" > /etc/init/keystone.override

apt-get -y --force-yes install keystone apache2 libapache2-mod-wsgi  memcached python-memcache
systemctl restart memcached

#Keystone.conf file is preconfigured and stored in a mounted shared folder - See Vagrant file
cat > /etc/keystone/keystone.conf <<RE_EOF
[DEFAULT]
admin_token = openstack
log_dir = /var/log/keystone

[database]
connection = mysql+pymysql://keystone:openstack@$IP/keystone

[memcache]
servers = localhost:11211

[revoke]
driver = sql

[token]
provider = uuid
driver = memcache

[extra_headers]
Distribution = Ubuntu
RE_EOF

su -s /bin/sh -c "keystone-manage db_sync" keystone

#Configure the Apache HTTP server
echo "ServerName $IP" >> /etc/apache2/apache2.conf

if [ "$OS_VERSION" = "mitaka" ] ; then
cat > /etc/apache2/sites-available/wsgi-keystone.conf <<RE_CONF
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /usr/bin/keystone-wsgi-public
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /usr/bin/keystone-wsgi-admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>
RE_CONF

ln -s /etc/apache2/sites-available/wsgi-keystone.conf /etc/apache2/sites-enabled

 systemctl stop keystone 
 systemctl disable keystone 
fi

#Restart the Apache HTTP server:
service apache2 restart
systemctl status apache2.service
journalctl -xe

rm -f /var/lib/keystone/keystone.db

#Create the service entity and API endpoints
OS_TOKEN=$admin_token
OS_URL=http://$IP:35357/v3
OS_IDENTITY_API_VERSION=3


keystone-manage bootstrap \
   --bootstrap-password openstack \
   --bootstrap-username admin \
   --bootstrap-project-name admin \
   --bootstrap-role-name admin \
   --bootstrap-service-name keystone \
   --bootstrap-region-id RegionOne \
   --bootstrap-admin-url http://$IP:35357 \
   --bootstrap-public-url http://$EXTIP:5000 \
   --bootstrap-internal-url http://$IP:5000


openstack --os-url $OS_URL --os-token $OS_TOKEN --os-identity-api-version $OS_IDENTITY_API_VERSION project create --domain default --description "Service Project" service

#Create the demo project:
openstack --os-url $OS_URL --os-token $OS_TOKEN --os-identity-api-version $OS_IDENTITY_API_VERSION project create --domain default --description "Demo Project" demo
openstack --os-url $OS_URL --os-token $OS_TOKEN --os-identity-api-version $OS_IDENTITY_API_VERSION user create --domain default --password openstack demo
openstack --os-url $OS_URL --os-token $OS_TOKEN --os-identity-api-version $OS_IDENTITY_API_VERSION role create user
openstack --os-url $OS_URL --os-token $OS_TOKEN --os-identity-api-version $OS_IDENTITY_API_VERSION role add --project demo --user demo user

#source admin-openrc.sh
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=openstack
export OS_AUTH_URL=http://$IP:35357/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
openstack token issue

#Install and configure controller node for Neutron
#Database creation is done at the beginning of the script

openstack user create --domain default --password openstack neutron
openstack role add --project service --user neutron admin
openstack role create _member_
openstack service create --name neutron --description "OpenStack Networking" network
openstack endpoint create --region RegionOne network public http://$IP:9696
openstack endpoint create --region RegionOne network internal http://$IP:9696
openstack endpoint create --region RegionOne network admin http://$IP:9696

apt-get -y install neutron-server python-neutronclient python-neutron-lbaas  python-neutron-fwaas
cp /etc/neutron/neutron.conf /etc/neutron/neutron.conf.bak
crudini --set /etc/neutron/neutron.conf DEFAULT rpc_backend fake
crudini --set /etc/neutron/neutron.conf database connection mysql+pymysql://neutron:openstack@$IP/neutron
crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_uri http://$IP:5000
crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_url http://$IP:35357
crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_plugin password
crudini --set /etc/neutron/neutron.conf keystone_authtoken project_domain_id default
crudini --set /etc/neutron/neutron.conf keystone_authtoken user_domain_id default
crudini --set /etc/neutron/neutron.conf keystone_authtoken project_name service
crudini --set /etc/neutron/neutron.conf keystone_authtoken username neutron
crudini --set /etc/neutron/neutron.conf keystone_authtoken password openstack

su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
     --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron

systemctl restart neutron-server

