#!/bin/bash

# VARIABLE DICLARAION

######################## 1 : Selinux status #########################################
selinux ()
{
if [ "`cat /etc/selinux/config |grep -v "^#"|grep -w SELINUX | cut -d = -f 2`" == "disabled" ]; then
     echo -e " "
     echo -e "[ $GREEN OK  $NC ] Selinux is diabled"
else
     echo -e " "
     echo -e "[ $RED ALERT $NC ] $BGRED Selinux is not disbled, we are in the process to diable it  $NBG" 
    `sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config`
     echo -e "[ $GREEN OK  $NC ] $GREEN Selinux has been successfully  diabled, now system is rebooting, please run DVD2 again after reboot $NC"
     sleep 5
     init 6
fi
}
########################## 2 : Firewall status #####################################

firewall ()
{
if [ "`systemctl status  firewalld | awk 'NR==2 {print substr($4, 1, length($4)-1) }'`" == "disabled" ]; then
      echo -e " "
      echo -e "[ $GREEN OK  $NC ] Firewall is disabled "
else
      echo  -e ""
      echo -e "[$RED ALERT $NC] $BGRED Firewall is not disbale, we are in process to disable it $NBG"
      systemctl stop firewalld.service
      systemctl disable firewalld.service

if [ "`systemctl status  firewalld | awk 'NR==2 {print substr($4, 1, length($4)-1) }'`" == "disabled" ]; then
      echo -e " "
      echo -e "[ $GREEN OK  $NC ] Firewall is disabled "
else
    echo -e "We facing some issue to disable firewall, Please do it Manually" && exit 0
fi

fi
}
########################## 3 : Package Install #####################################
install_packages () 
{
  local packages=("git" "wget" "bind" "bind-utils" "httpd" "haproxy")
  local missing_packages=()

  for package in "${packages[@]}"; do
    if ! rpm -q "$package" &>/dev/null; then
      missing_packages+=("$package")
    fi
  done

  if [ ${#missing_packages[@]} -eq 0 ]; then
    echo "All required packages are already installed."
  else
    echo "Installing missing packages: ${missing_packages[*]}"
    sudo yum install -y "${missing_packages[@]}"
  fi
}

########################## 4 : Configuration Update #####################################
conf_update ()
{
  yes | cp -rvp `pwd`/data/dns/*.zone /var/named/.
  yes | cp -rvp `pwd`/data/dns/named.conf /etc/.
  yes | cp -rvp `pwd`/data/dns/resolv.conf /etc/.
  yes | cp -rvp `pwd`/data/haproxy/haproxy.cfg /etc/haproxy/.
}

service_update ()
{
  systemctl enable --now named haproxy 
}

static_dns ()
{
  systemctl disable --now NetworkManager
  printf "[main]\ndns=none\n" > /etc/NetworkManager/conf.d/no-resolv.conf
  systemctl restart network-online.target
}

# Fuction Call
selinux
firewall
install_packages
conf_update
service_update
static_dns
