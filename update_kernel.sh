#!/bin/bash

##Import the GPG key for the repository

rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org

##Install the repository

yum install http://www.elrepo.org/elrepo-release-7.0-2.el7.elrepo.noarch.rpm -y

##Enable the repository

yum --enablerepo=elrepo-kernel install kernel-ml -y

## List all available kernels

awk -F\' '$1=="menuentry " {print $2}' /etc/grub2.cfg > /tmp/tmp-$1.txt

VAR="$(grep -n $1 /tmp/tmp-$1.txt |cut -f1 -d:)"

##select the new kernel

if [ ! -z "$VAR" ]
then
   grub2-set-default $((VAR - 1))
else
   exit 0
fi
##Save your new configuration
grub2-mkconfig -o /boot/grub2/grub.cfg

#Restart 
init6
