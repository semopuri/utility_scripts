#!/bin/bash

##Author:Kumar.S##
#To do : Description   
#comment debug
#format


# Safety feature: exit script if error is returned, or if variables not set.
# Exit if a pipeline results in an error.
set -ue
set -o pipefail

##set env variable ##
export PATH=$PATH:/usr/local/bin/:/usr/bin 
export https_proxy=
export http_proxy=
export no_proxy=


## Automatic EBS Volume Snapshot Creation & Clean-Up Script

## Variable Declartions ##
conf_file=/tmp/conf 
ctr=0

# Set Logging Options
logfile="/var/log/snap-bot.log"
logfile_max_lines="5000"

# Retention 7 days
retention_days="7"
retention_date_in_seconds=$(date +%s --date "$retention_days days ago")

## Function Declarations ##

# Function: Setup logfile and redirect stdout/stderr.
log_setup() {
    # Check if logfile exists and is writable.
    ( [ -e "$logfile" ] || touch "$logfile" ) && [ ! -w "$logfile" ] && echo "ERROR: Cannot write to $logfile. Check permissions or sudo access." && exit 1

    tmplog=$(tail -n $logfile_max_lines $logfile 2>/dev/null) && echo "${tmplog}" > $logfile
    exec > >(tee -a $logfile)
    exec 2>&1
}

# Function: Log an event.
log() {
    echo "[$(date +"%Y-%m-%d"+"%T")]: $*"
}

# Function: Confirm that the AWS CLI and related tools are installed.
prerequisite_check() {
	for prerequisite in aws wget; do
		hash $prerequisite &> /dev/null
		if [[ $? == 1 ]]; then
			echo "In order to use this script, the executable \"$prerequisite\" must be installed." 1>&2; exit 70
		fi
	done
}

##Get Instances with the tag:value Automatedbackup:enable##
get_instance_details(){
     aws ec2 describe-instances --filter Name=tag:auto-snapshot,Values=enable  --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone]'>$conf_file
     [ ! -f "$conf_file" ] && { echo "Error: $0 file not found."; exit 1; }
     
     if [ -s "$conf_file" ];then
        read_conf_file $conf_file
     else
	echo "unable to fetch instance details "
        exit 2;
      fi
}

#Function : read from /tmp/conf
read_conf_file(){
	while read line
 	do
		instance_id[$ctr]=$(echo $line |cut -d ' ' -f 1)
		region[$ctr]=$(echo $line| sed -e 's/\([1-9]\).$/\1/g' |cut -d ' ' -f 2)
		((ctr+=1))
	done<$1
}

# Function: Snapshot all volumes attached to this instance.
snapshot_volumes() {
	for volume_id in $volume_list; do
		log "Volume ID :$volume_id"
        log "region:$1"
        region=$1
		# Get the attched device name to add to the description so we can easily tell which volume this is.
		device_name=$(aws ec2 describe-volumes --region $region --output=text --volume-ids $volume_id --query 'Volumes[0].{Devices:Attachments[0].Device}')

		# Take a snapshot of the current volume, and capture the resulting snapshot ID
		snapshot_description="$device_name-backup-$(date +%Y-%m-%d)"

		snapshot_id=$(aws ec2 create-snapshot --region $region --output=text --description $snapshot_description --volume-id $volume_id --query SnapshotId)
		log "New snapshot is $snapshot_id"
	 
		#Add a "Name:resourceId-name" tag to snapshot
		aws ec2 create-tags --region $region --resource $snapshot_id --tags Key=Name,Value=$2
		# Add a "snap-bot:AutomatedBackup" tag to the resulting snapshot.
        aws ec2 create-tags --region $region --resource $snapshot_id --tags Key=snap-bot,Value=AutomatedBackup
	done
}

# Function: Cleanup all snapshots associated with this instance that are older than $retention_days
cleanup_snapshots() {
        region=$1
	for volume_id in $volume_list; do
		snapshot_list=$(aws ec2 describe-snapshots --region $region --output=text --filters "Name=volume-id,Values=$volume_id" "Name=tag:snap-bot,Values=AutomatedBackup" --query Snapshots[].SnapshotId)
		for snapshot in $snapshot_list; do
			log "Checking $snapshot..."
			# Check age of snapshot
			snapshot_date=$(aws ec2 describe-snapshots --region $region --output=text --snapshot-ids $snapshot --query Snapshots[].StartTime | awk -F "T" '{printf "%s\n", $1}')
			snapshot_date_in_seconds=$(date "--date=$snapshot_date" +%s)
			snapshot_description=$(aws ec2 describe-snapshots --snapshot-id $snapshot --region $region --query Snapshots[].Description)

			if (( $snapshot_date_in_seconds <= $retention_date_in_seconds )); then
				log "DELETING snapshot $snapshot. Description: $snapshot_description ..."
				aws ec2 delete-snapshot --region $region --snapshot-id $snapshot
			else
				log "Not deleting snapshot $snapshot. Description: $snapshot_description ..."
			fi
		done
	done
}	

##########################################
############ main Execution ##############
##########################################
log_setup
prerequisite_check
get_instance_details
  
for (( i=0; i<ctr; i++ ));do
    log " InstanceID:${instance_id[$i]}"
    volume_list=$(aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=${instance_id[$i]} --query Volumes[].VolumeId --output text)
    resource_name=$(aws ec2 describe-tags --filters Name=resource-id,Values=${instance_id[$i]} | grep Name | awk -F ' ' '{print $5}')
    snapshot_volumes ${region[$i]} $resource_name 
    #sleep 300
    cleanup_snapshots ${region[$i]}
done
exit 0
