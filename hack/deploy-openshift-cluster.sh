#!/bin/bash

set -euo pipefail

if [ -z "${OPENSHIFT_INSTALL_PULL_SECRET_PATH:-}" ] ; then
    echo ERROR: You must provide a pull secret
    echo specify a path to the file in \$OPENSHIFT_INSTALL_PULL_SECRET_PATH
    echo the file should be the file downloaded from https://cloud.openshift.com/clusters/install
    echo Step 4: Deploy the Cluster - Download Pull Secret
    exit 1
fi

if [ -z "${WORKDIR:-}" ] ; then
    echo ERROR: you must provide \$WORKDIR into which the new cluster
    echo auth credentials will be written - the installer will create
    echo \$WORKDIR/auth/kubeadmin-password and kubeconfig
    exit 1
elif [ ! -d $WORKDIR ] ; then
    mkdir -p $WORKDIR
fi

installdir=$WORKDIR/installdir
if [ ! -d $installdir ] ; then
    mkdir -p $installdir
fi

OPENSHIFT_INSTALL_PLATFORM_ARCH=${OPENSHIFT_INSTALL_PLATFORM_ARCH:-linux-amd64}
OPENSHIFT_INSTALL_PLATFORM=${OPENSHIFT_INSTALL_PLATFORM:-aws}
OPENSHIFT_INSTALL_SSH_PUB_KEY_PATH=${OPENSHIFT_INSTALL_SSH_PUB_KEY_PATH:-$HOME/.ssh/id_rsa.pub}
OPENSHIFT_INSTALL_NUM_WORKERS=${OPENSHIFT_INSTALL_NUM_WORKERS:-3}
OPENSHIFT_INSTALL_NUM_MASTERS=${OPENSHIFT_INSTALL_NUM_MASTERS:-3}

if [ $OPENSHIFT_INSTALL_PLATFORM = aws ] ; then
    OPENSHIFT_INSTALL_BASE_DOMAIN=${OPENSHIFT_INSTALL_BASE_DOMAIN:-devcluster.openshift.com}
    OPENSHIFT_INSTALL_CLUSTER_NAME=${OPENSHIFT_INSTALL_CLUSTER_NAME:-${USER}-log}
    OPENSHIFT_INSTALL_AWS_REGION=${OPENSHIFT_INSTALL_AWS_REGION:-us-east-1}
    export AWS_PROFILE=${AWS_PROFILE:-default}
fi

if [ -n "${OPENSHIFT_INSTALLER:-}" -a -x "${OPENSHIFT_INSTALLER:-}" ] ; then
    INSTALLER=$OPENSHIFT_INSTALLER
elif [ -n "${OPENSHIFT_INSTALLER_URL:-}" ] ; then
    INSTALLER=$installdir/openshift-install
    pushd $WORKDIR > /dev/null
    curl -s -L -o openshift-installer.tar.gz "$OPENSHIFT_INSTALLER_URL"
    tar xfz openshift-installer.tar.gz
    mv openshift-install $INSTALLER
    popd > /dev/null
elif [ -n "${OPENSHIFT_INSTALL_VERSION:-}" ] ; then
    # download and use specific version
    INSTALLER=$installdir/openshift-install
    case $OPENSHIFT_INSTALL_VERSION in
        4.*) pushd $WORKDIR > /dev/null
             curl -s -L -o openshift-install-linux-${OPENSHIFT_INSTALL_VERSION}.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-install-linux-${OPENSHIFT_INSTALL_VERSION}.tar.gz
             tar xfz openshift-install-linux-${OPENSHIFT_INSTALL_VERSION}.tar.gz
             mv openshift-install $INSTALLER
             popd > /dev/null ;;
        *) curl -s -L -o $INSTALLER https://github.com/openshift/installer/releases/download/${OPENSHIFT_INSTALL_VERSION}/openshift-install-${OPENSHIFT_INSTALL_PLATFORM_ARCH} ;;
    esac
else
    pkgstoinstall=""
    for pkg in golang-bin gcc-c++ libvirt-devel ; do
        if ! rpm -q $pkg > /dev/null 2>&1 ; then
            pkgstoinstall="$pkgstoinstall $pkg"
        fi
    done
    if [ -n "$pkgstoinstall" ] ; then
        yum -y install $pkgstoinstall
    fi
    if [ -d $GOPATH/src/github.com/openshift/installer ] ; then
        pushd $GOPATH/src/github.com/openshift/installer > /dev/null
        git pull
    else
        pushd $installdir > /dev/null
        git clone https://github.com/openshift/installer
        cd installer
    fi
    hack/build.sh > $WORKDIR/installer-build.log 2>&1
    INSTALLER=$( pwd )/bin/openshift-install
    popd > /dev/null
fi

pushd $installdir > /dev/null

if [ $OPENSHIFT_INSTALL_PLATFORM = aws ] ; then
    cat > install-config.yaml <<EOF
apiVersion: v1
baseDomain: $OPENSHIFT_INSTALL_BASE_DOMAIN
compute:
- hyperthreading: Enabled
  name: worker
  replicas: $OPENSHIFT_INSTALL_NUM_WORKERS
  platform:
    aws:
      type: ${OPENSHIFT_INSTALL_WORKER_TYPE:-m4.xlarge}
controlPlane:
  hyperthreading: Enabled
  name: master
  replicas: $OPENSHIFT_INSTALL_NUM_MASTERS
  platform: {}
metadata:
  name: ${OPENSHIFT_INSTALL_CLUSTER_NAME}
networking:
  clusterNetworks:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineCIDR: 10.0.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: $OPENSHIFT_INSTALL_AWS_REGION
pullSecret: '$( cat $OPENSHIFT_INSTALL_PULL_SECRET_PATH )'
sshKey: |
  $( cat $OPENSHIFT_INSTALL_SSH_PUB_KEY_PATH )
EOF
fi

if $INSTALLER --dir $installdir create cluster ; then
    cp -r $installdir/auth $WORKDIR
else
    echo ERROR: installation failed - cleaning up cluster
    $INSTALLER --dir $installdir destroy cluster || :
    exit 1
fi
