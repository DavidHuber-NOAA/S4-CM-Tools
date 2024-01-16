#!/usr/bin/bash
#Name: Global workflow nightly build script
#Purpose: Clone and build the global workflow and report any issues via email.  Intended to run nightly via cron.
#Author: David Huber (dhuber@redlineperf.com)
#Date: 5/19/2021

die() { echo "$@" >&2; exit 1; }
usage() {
  set +x
  echo
  echo "Usage: $0 -p | -b | -c | -n | -h"
  echo
  echo "  -p <URL>         URL to global workflow repository (default: git@github.com:DavidHuber-NOAA/global-workflow)"
  echo "  -b <branch name> Git branch name (default: gfsv16b_port_2_s4)"
  echo "  -n <test name>   Name of the test (default: gw_nightly_build)"
  echo "  -h               Display this help"
  echo
  set -x
  exit 1
}

if [ -f /etc/bashrc ]; then
   . /etc/bashrc
   source /etc/profile
fi

module load git

#set -x

#Defined paths
export HOMEDIR="/data/users/dhuber"
export TEST_NAME="gw_nightly_build"
#Repo/branch paths
#Set defaults
export GITHUB_PATH="git@github.com:NOAA-EMC/global-workflow"
export GW_BRANCH="develop"
#Modify if specified
while getopts ":p:b:" opt; do
   case $opt in
      p)
         export GITHUB_PATH=$OPTARG
         ;;
      b)
         export GW_BRANCH=$OPTARG
         ;;
      n)
         export TEST_NAME=$OPTARG
         ;;
      h)
         usage
         ;;
      \?)
         usage
         die "Invalid option: -$opt"
         ;;
      :)
         usage
         die "Option -$opt requires an argument"
         ;;
   esac
done

#Build directory path names
export GW_ROOT_PATH="${HOMEDIR}/$TEST_NAME"
export SOURCE_DIR="${GW_ROOT_PATH}/sorc"

#Notification email address
export EMAIL_ADDR="dhuber@redlineperf.com"

#Navigate to the root directory
cd $HOMEDIR

#Check if the nightly build folder exists (indicates yesterday's attempt failed)
if [ -e $GW_ROOT_PATH ]; then
   #Send out an email if the directory already exists
   message="$GW_ROOT_PATH already exists!  Cannot perform nightly build!"
   echo $message
   cat > email.txt << EOF
      Subject: Nightly build failure
      $message
EOF
   sendmail $EMAIL_ADDR < email.txt
   rm -f email.txt
   exit 1
fi

#Clone the repository
git clone $GITHUB_PATH $GW_ROOT_PATH --recursive -j 4
if [[ $? -ne 0 ]]; then
   message="Failed to checkout $GITHUB_PATH to $GW_ROOT_PATH, aborting nightly build!"
   echo $message
   cat > email.txt << EOF
      Subject: Nightly build failure
      $message
EOF
   sendmail $EMAIL_ADDR < email.txt
   rm -f email.txt
   exit 2
fi

#Checkout the branch
cd $GW_ROOT_PATH
git checkout $GW_BRANCH
git submodule update --init --recursive -j 4

#Check for checkout errors
ERR=$?
#Check the log for errors as well; treat warnings as errors
if grep -iq "fatal\|fail\|error\|warning" checkout.log; then
   if [[ $ERR -eq 0 ]]; then
      $ERR=1
   fi
fi

#Report if there was a problem checking out the repo
if [[ $ERR -ne 0 ]]; then
   echo "Failed to checkout the global workflow"
   cat > email.txt << EOF
      Subject: Nightly build failure
      During the nightly build, the script checkout.sh failed to checkout all modules.
EOF
   sendmail $EMAIL_ADDR < email.txt
   rm -f email.txt

   exit $ERR
fi

#Build the workflow
cd $SOURCE_DIR
timeout 10800 ./build_all.sh -g 2>&1 | tee build.log

#Check for errors
ERR=$?
timeout_err=0
script_err=0

#Check for a timeout error 124
if [[ $ERR -eq 124 ]]; then
   timeout_err=1
   echo "The build timed out"
#Check for any other error
elif [[ $ERR -ne 0 ]]; then
   script_err=1
   echo "A problem occurred with the build script, code: $ERR"
fi

#Also check the logs for errors; treat warnings as errors
log_err=0
if grep -iq "fatal\|fail\|error\|warning" build.log; then
   echo Found an error in the log file
   log_err=1
   if [[ $ERR -eq 0 ]]; then
      ERR=1
   fi
fi

#If an error was found, then report it
if [[ $ERR -ne 0 ]]; then

   echo "One or more builds failed"
   cat > email.txt << EOF
      Subject: Nightly build failure
      During the nightly build, one or more programs failed to build.  The log from the build follows.
EOF

   cat build.log >> email.txt

   if [[ $timeout_err -eq 1 ]] ; then
      echo "<The compilation then timed out>" >> email.txt
   fi

   if [[ $log_err -eq 1 ]] ; then
      echo "<One or more of the builds reported an error>" >> email.txt
   fi

   if [[ $script_err -ne 0 ]] ; then
      echo "<A problem occurred with the build script>" >> email.txt
   fi

   sendmail $EMAIL_ADDR < email.txt
   rm -f email.txt
   exit $ERR

#If everything went OK, then delete the test build directory
else
   cd $HOMEDIR
   rm -rf $GW_ROOT_PATH
   exit 0
fi
