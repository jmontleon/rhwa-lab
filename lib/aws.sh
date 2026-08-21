#!/usr/bin/env bash
# aws.sh - EC2 instance, keypair, security group, Elastic IP, Route53 records.

# Resolve ROUTE53_ZONE_ID to a real hosted-zone id. Accepts:
#   - an existing zone id (Z...)         -> used as-is
#   - a domain name (migration.redhat.com) -> looked up
#   - unset                              -> resolved from BASE_DOMAIN
# Falls back to the closest parent zone (e.g. redhat.com) if needed.
resolve_r53_zone() {
  if [[ "${ROUTE53_ZONE_ID:-}" =~ ^Z[A-Z0-9]+$ ]]; then
    state_set r53_zone "$ROUTE53_ZONE_ID"; return 0
  fi
  local domain try id
  domain="${ROUTE53_ZONE_ID:-$BASE_DOMAIN}"; domain="${domain%.}"
  try="$domain"
  while [[ "$try" == *.* ]]; do
    id="$(aws route53 list-hosted-zones-by-name --dns-name "${try}." \
          --query "HostedZones[?Name=='${try}.'].Id|[0]" --output text 2>/dev/null)"
    if [[ -n "$id" && "$id" != "None" ]]; then
      ROUTE53_ZONE_ID="${id#/hostedzone/}"
      state_set r53_zone "$ROUTE53_ZONE_ID"
      log "Resolved Route53 zone for ${domain}: ${ROUTE53_ZONE_ID} (${try}.)"
      return 0
    fi
    try="${try#*.}"   # drop leftmost label, try the parent domain
  done
  die "No Route53 hosted zone found for ${domain} (or any parent domain).
Set ROUTE53_ZONE_ID to a zone id (Z...) or a domain you own in Route53."
}

aws_preflight() {
  log "AWS preflight checks"
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "AWS credentials invalid or not set (check AWS_ACCESS_KEY_ID / AWS_PROFILE)."

  resolve_r53_zone

  # Instance type available in this region?
  local offered
  offered="$(aws ec2 describe-instance-type-offerings \
      --location-type region \
      --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
      --query 'InstanceTypeOfferings[0].InstanceType' --output text 2>/dev/null)"
  [[ "$offered" == "$INSTANCE_TYPE" ]] \
    || die "Instance type ${INSTANCE_TYPE} is not offered in ${AWS_REGION}. Pick another region/type."

  # vCPU quota (advisory only; codes/limits vary).  L-1216C47A = Standard On-Demand vCPUs.
  local quota need=48
  quota="$(aws service-quotas get-service-quota --service-code ec2 \
      --quota-code L-1216C47A --query 'Quota.Value' --output text 2>/dev/null || echo '')"
  if [[ -n "$quota" && "${quota%.*}" -lt "$need" ]]; then
    warn "On-Demand Standard vCPU quota is ${quota%.*}; ${INSTANCE_TYPE} needs ~${need}. Launch may fail - request an increase."
  fi

  # Route53 zone reachable?
  aws route53 get-hosted-zone --id "$ROUTE53_ZONE_ID" >/dev/null 2>&1 \
    || die "Route53 hosted zone ${ROUTE53_ZONE_ID} not found or not accessible."
  ok "AWS preflight passed"
}

aws_import_keypair() {
  [[ -f "$SSH_PUBLIC_KEY_FILE" ]] || die "SSH public key not found: ${SSH_PUBLIC_KEY_FILE}"
  [[ -f "$PRIV_KEY" ]] || warn "Private key ${PRIV_KEY} not found; ssh to host/nodes will fail."
  if aws ec2 describe-key-pairs --key-names "$KEYPAIR_NAME" >/dev/null 2>&1; then
    log "Reusing existing EC2 keypair ${KEYPAIR_NAME}"
  else
    log "Importing EC2 keypair ${KEYPAIR_NAME}"
    aws ec2 import-key-pair --key-name "$KEYPAIR_NAME" \
      --public-key-material "fileb://${SSH_PUBLIC_KEY_FILE}" >/dev/null
    state_set keypair_created yes
  fi
  state_set keypair_name "$KEYPAIR_NAME"
}

aws_security_group() {
  local vpc sg myip
  vpc="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text)"
  [[ "$vpc" == "None" || -z "$vpc" ]] && die "No default VPC in ${AWS_REGION}; create one or extend the script."
  state_set vpc_id "$vpc"

  sg="$(state_get sg_id)"
  if [[ -z "$sg" ]]; then
    sg="$(aws ec2 create-security-group --group-name "$SG_NAME" \
          --description "rhwa-lab ${CLUSTER_NAME}" --vpc-id "$vpc" \
          --query 'GroupId' --output text)"
    state_set sg_id "$sg"
    ok "Created security group ${sg}"
  fi

  myip="$(curl -fsS https://checkip.amazonaws.com 2>/dev/null || echo '0.0.0.0')"
  myip="${myip%%$'\n'*}/32"
  # SSH restricted to caller; cluster ports open to the internet (per design).
  _sg_allow() { aws ec2 authorize-security-group-ingress --group-id "$sg" \
                  --ip-permissions "$1" >/dev/null 2>&1 || true; }
  _sg_allow "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${myip}}]"
  _sg_allow "IpProtocol=tcp,FromPort=6443,ToPort=6443,IpRanges=[{CidrIp=0.0.0.0/0}]"
  _sg_allow "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]"
  _sg_allow "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]"
  ok "Security group rules applied (ssh from ${myip}; 6443/443/80 open)"
}

aws_launch_instance() {
  if state_has instance_id; then
    log "Instance already recorded ($(state_get instance_id)); skipping launch"
    return 0
  fi
  # Fedora Cloud Base (owner = Fedora Project, 125523088429) has the full
  # virtualization stack (libvirt/qemu-kvm/virt-install/podman); default user
  # is 'fedora' (HOST_SSH_USER). AL2023 does NOT ship these packages.
  # Override the image with HOST_AMI (also set HOST_SSH_USER to match).
  local ami root_dev
  ami="${HOST_AMI:-}"
  if [[ -z "$ami" ]]; then
    ami="$(aws ec2 describe-images --owners 125523088429 \
        --filters "Name=name,Values=Fedora-Cloud-Base-AmazonEC2*-${FEDORA_RELEASE}-*" \
                  "Name=architecture,Values=x86_64" \
                  "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text 2>/dev/null)"
  fi
  [[ -z "$ami" || "$ami" == "None" ]] \
    && die "Could not resolve Fedora ${FEDORA_RELEASE} Cloud AMI in ${AWS_REGION}. Set HOST_AMI (+ HOST_SSH_USER) to a virtualization-capable image."
  # Root device name varies by AMI (CentOS uses /dev/sda1); resize that volume.
  root_dev="$(aws ec2 describe-images --image-ids "$ami" \
      --query 'Images[0].RootDeviceName' --output text 2>/dev/null)"
  [[ -z "$root_dev" || "$root_dev" == "None" ]] && root_dev="/dev/sda1"
  log "Launching ${INSTANCE_TYPE} from ${ami} (root ${root_dev}, nested virt enabled)"

  local iid
  iid="$(aws ec2 run-instances \
      --image-id "$ami" \
      --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEYPAIR_NAME" \
      --security-group-ids "$(state_get sg_id)" \
      --cpu-options "NestedVirtualization=enabled" \
      --block-device-mappings "DeviceName=${root_dev},Ebs={VolumeSize=${EC2_VOLUME_SIZE_GB},VolumeType=gp3,DeleteOnTermination=true}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}},{Key=rhwa-lab,Value=${CLUSTER_NAME}}]" \
      --query 'Instances[0].InstanceId' --output text)"
  [[ -z "$iid" || "$iid" == "None" ]] && die "run-instances failed."
  state_set instance_id "$iid"
  ok "Instance ${iid} launching"

  log "Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "$iid"

  # Elastic IP
  local alloc eip
  alloc="$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)"
  state_set eip_alloc_id "$alloc"
  aws ec2 associate-address --instance-id "$iid" --allocation-id "$alloc" >/dev/null
  eip="$(aws ec2 describe-addresses --allocation-ids "$alloc" \
        --query 'Addresses[0].PublicIp' --output text)"
  state_set eip "$eip"
  ok "Elastic IP ${eip} associated"

  log "Waiting for SSH on ${eip}..."
  retry 30 10 -- ssh_host true || die "SSH to host never came up."
  ok "Host reachable over SSH"
}

# Route53 UPSERT/DELETE for api + *.apps -> Elastic IP
_r53_change() {   # <action>
  local action="$1" eip zone
  eip="$(state_get eip)"
  # Prefer the resolved zone id persisted at preflight (so destroy works even
  # when ROUTE53_ZONE_ID in the env is a domain name, or unset).
  zone="$(state_get r53_zone)"; [[ -n "$zone" ]] || zone="$ROUTE53_ZONE_ID"
  local batch
  batch="$(cat <<JSON
{"Changes":[
 {"Action":"${action}","ResourceRecordSet":{"Name":"$(api_fqdn).","Type":"A","TTL":60,"ResourceRecords":[{"Value":"${eip}"}]}},
 {"Action":"${action}","ResourceRecordSet":{"Name":"$(apps_fqdn).","Type":"A","TTL":60,"ResourceRecords":[{"Value":"${eip}"}]}}
]}
JSON
)"
  aws route53 change-resource-record-sets --hosted-zone-id "$zone" \
    --change-batch "$batch" --query 'ChangeInfo.Id' --output text
}

aws_dns_upsert() {
  log "Creating Route53 records -> $(state_get eip)"
  _r53_change UPSERT >/dev/null
  state_set dns_created yes
  ok "DNS: $(api_fqdn) and $(apps_fqdn) -> $(state_get eip)"
}

aws_dns_delete() {
  [[ "$(state_get dns_created)" == "yes" ]] || return 0
  [[ -n "$(state_get eip)" ]] || return 0
  log "Deleting Route53 records"
  _r53_change DELETE >/dev/null 2>&1 || warn "Route53 delete failed (may already be gone)."
}

aws_teardown() {
  local iid eip alloc sg
  iid="$(state_get instance_id)"; alloc="$(state_get eip_alloc_id)"; sg="$(state_get sg_id)"

  aws_dns_delete

  if [[ -n "$iid" ]]; then
    log "Terminating instance ${iid}"
    aws ec2 terminate-instances --instance-ids "$iid" >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --instance-ids "$iid" 2>/dev/null || true
  fi
  if [[ -n "$alloc" ]]; then
    log "Releasing Elastic IP"
    aws ec2 release-address --allocation-id "$alloc" >/dev/null 2>&1 || true
  fi
  if [[ -n "$sg" ]]; then
    log "Deleting security group ${sg}"
    retry 6 10 -- aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 \
      || warn "Could not delete SG ${sg} (dependencies may linger)."
  fi
  if [[ "$(state_get keypair_created)" == "yes" ]]; then
    log "Deleting EC2 keypair ${KEYPAIR_NAME}"
    aws ec2 delete-key-pair --key-name "$KEYPAIR_NAME" >/dev/null 2>&1 || true
  fi
  ok "AWS resources removed"
}
