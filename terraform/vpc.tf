/******************************************************************************
 *
 * vpc.tf - IAM profile, security groups, and instances
 *
 ******************************************************************************/

provider "aws" {
  region = "${var.aws_region}"
  access_key = "${var.aws_access_key_id}"
  secret_key = "${var.aws_secret_access_key}"
}

resource "aws_vpc" "vpc" {

  cidr_block = "${var.vpc_network_cidr}"
  enable_dns_support = "true"
  enable_dns_hostnames = "true"
  assign_generated_ipv6_cidr_block = true

  tags {
    Name = "vpc-${var.Project}-${var.Lifecycle}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
}

/* Subnet to put instances on */
resource "aws_subnet" "instances" {
  count = "${var.vpc_subnet_count}"
  
  vpc_id = "${aws_vpc.vpc.id}"
  cidr_block = "${cidrsubnet(var.vpc_network_cidr, var.vpc_subnet_network_bits, (count.index+1) * 2)}"
  availability_zone = "${element(split(",",lookup(var.aws_availability_zones, var.aws_region)), count.index % length(split(",",lookup(var.aws_availability_zones, var.aws_region))))}"

  map_public_ip_on_launch = true
  ipv6_cidr_block = "${cidrsubnet(aws_vpc.vpc.ipv6_cidr_block, 8, (count.index+1) * 2)}" /* Even numbered /64 networks are for instances eth0 */
  assign_ipv6_address_on_creation = true

  tags {
    Name = "subnet${count.index}-${var.Project}-${var.Lifecycle}-da"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = "${aws_vpc.vpc.id}"

  tags {
    Name = "igw-${var.Project}-${var.Lifecycle}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
}

resource "aws_route_table" "default" {
  vpc_id = "${aws_vpc.vpc.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.igw.id}"
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id = "${aws_internet_gateway.igw.id}"
  }

  tags {
    Name = "route-${var.Project}-${var.Lifecycle}-default"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
}

resource "aws_route_table_association" "default" {
  count = "${var.vpc_subnet_count}"
  
  subnet_id = "${element(aws_subnet.instances.*.id, count.index)}"
  route_table_id = "${aws_route_table.default.id}"
}

resource "aws_security_group" "sg" {
  name = "${var.Project}-${var.Lifecycle}"
  description = "Security Group for ${var.Project}-${var.Lifecycle}"
  vpc_id = "${aws_vpc.vpc.id}"

  tags {
      Name = "sg-${var.Project}-${var.Lifecycle}"
      Project = "${var.Project}"
      Lifecycle = "${var.Lifecycle}"
  }
}

resource "aws_security_group_rule" "sg_ingress_ssh" {
    type = "ingress"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]

    security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "sg_ingress_da" {
    type = "ingress"
    from_port = "${var.tor_daport}"
    to_port = "${var.tor_daport}"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]

    security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "sg_ingress_https" {
    type = "ingress"
    from_port = "443"
    to_port = "443"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]

    security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "sg_ingress_relay" {
    type = "ingress"
    from_port = "${var.tor_orport}"
    to_port = "${var.tor_orport}"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]

    security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "sg_ingress_all_icmp" {
    type = "ingress"
    from_port = -1
    to_port = -1
    protocol = "icmp"
    cidr_blocks = ["0.0.0.0/0"]

    security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "sg_ingress_all_icmpv6" {
    type = "ingress"
    from_port = -1
    to_port = -1
    protocol = "icmpv6"
    ipv6_cidr_blocks = ["::/0"]

    security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "sg_ingress_all_internal" {
    type = "ingress"
    from_port = 0
    to_port = 0
    protocol = "-1"
    security_group_id = "${aws_security_group.sg.id}"
    source_security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "sg_egress_all_out" {
    type = "egress"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_iam_role" "iam_role" {
    name = "${var.Project}-${var.Lifecycle}-instance_role"
    assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "iam_instance_profile" {
    name = "${var.Project}-${var.Lifecycle}-instance_profile"
    role = "${aws_iam_role.iam_role.name}"
}

resource "aws_key_pair" "ssh_key" {
  key_name = "${var.Project}-${var.Lifecycle}" 
  public_key = "${file("${var.ssh_key_path}")}"
}

/* Allocate and assign static IP to TOR DA role instances */

resource "aws_eip_association" "da" {
  count = "${var.tor_da_count}"

  instance_id   = "${element(aws_instance.da.*.id, count.index)}"
  allocation_id = "${element(aws_eip.da.*.id, count.index)}"
}

resource "aws_eip" "da" {
  count = "${var.tor_da_count}"

  vpc = true

  tags {
    Name = "${var.Project}-${var.Lifecycle}-da-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
}

/* Allocate and assign static IP to TOR BRIDGE role instances */

resource "aws_eip_association" "bridge" {
  count = "${var.tor_bridge_count}"

  instance_id   = "${element(aws_instance.bridge.*.id, count.index)}"
  allocation_id = "${element(aws_eip.bridge.*.id, count.index)}"
}

resource "aws_eip" "bridge" {
  count = "${var.tor_bridge_count}"

  vpc = true

  tags {
    Name = "${var.Project}-${var.Lifecycle}-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
}

/* Prepare the user-data for DA */

# Render a part using a `template_file`
data "template_file" "da" {
  count = "${var.tor_da_count}"

  template = "${file("tor-vpin.sh")}"

  vars {
    role = "DA"
    index = "${count.index}"
    ip = "${element(aws_eip.da.*.public_ip, count.index)}"
    hostname = "da${count.index}"
    da_hosts = "${join(",", aws_eip.da.*.public_ip)}"
    bridge_hosts = "${join(",", aws_eip.bridge.*.public_ip)}"
    tor_daport = "${var.tor_daport}"
    tor_orport = "${var.tor_orport}"
    s3_bucket = "${var.s3_bucket}"
  }
}

# Render a multi-part cloudinit config making use of the part
# above, and other source files
data "template_cloudinit_config" "da" {
  count = "${var.tor_da_count}"

  gzip          = true
  base64_encode = true

  # Setup hello world script to be called by the cloud-config
  part {
    content_type = "text/x-shellscript"
    content      = "${element(data.template_file.da.*.rendered, count.index)}"
  }
}

/* Create TOR DA role instances */

resource "aws_instance" "da" {
  count = "${var.tor_da_count}"
    
  availability_zone = "${element(split(",",lookup(var.aws_availability_zones, var.aws_region)), count.index % length(split(",",lookup(var.aws_availability_zones, var.aws_region))))}"
  
  instance_type = "${var.aws_instance_type}"
  ami = "${lookup(var.ami, "${var.aws_region}-${var.linux_distro_name}-${var.linux_distro_version}")}"
  
  iam_instance_profile = "${aws_iam_instance_profile.iam_instance_profile.id}"
  vpc_security_group_ids = [ "${aws_security_group.sg.id}" ]
  subnet_id = "${element(aws_subnet.instances.*.id, count.index)}"
  associate_public_ip_address = "true"
  ipv6_address_count = 1
  
  key_name = "${aws_key_pair.ssh_key.key_name}"

  connection {
    user = "ubuntu"
    key_file = "${var.ssh_key_path}"
  }

  tags {
    Name = "${var.Project}-${var.Lifecycle}-da-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
    
  root_block_device {
    volume_type = "standard"
    delete_on_termination = true
    volume_size = "${var.ebs_root_volume_size}"
  }

  volume_tags {
    Name = "${var.Project}-${var.Lifecycle}-da-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
  user_data = "${element(data.template_cloudinit_config.da.*.rendered, count.index)}"
}

/* Prepare the user-data for RELAY */

# Render a part using a `template_file`
data "template_file" "relay" {
  count = "${var.tor_relay_count}"

  template = "${file("tor-vpin.sh")}"

  vars {
    role = "RELAY"
    index = "${count.index}"
    ip = ""
    hostname = "relay${count.index}"
    da_hosts = "${join(",", aws_eip.da.*.public_ip)}"
    bridge_hosts = "${join(",", aws_eip.bridge.*.public_ip)}"
    tor_daport = "${var.tor_daport}"
    tor_orport = "${var.tor_orport}"
    s3_bucket = "${var.s3_bucket}"
  }
}

# Render a multi-part cloudinit config making use of the part
# above, and other source files
data "template_cloudinit_config" "relay" {
  count = "${var.tor_relay_count}"

  gzip          = true
  base64_encode = true

  # Setup hello world script to be called by the cloud-config
  part {
    content_type = "text/x-shellscript"
    content      = "${element(data.template_file.relay.*.rendered, count.index)}"
  }
}

/* Create TOR RELAY role instances */

resource "aws_instance" "relay" {
  count = "${var.tor_relay_count}"
    
  availability_zone = "${element(split(",",lookup(var.aws_availability_zones, var.aws_region)), count.index % length(split(",",lookup(var.aws_availability_zones, var.aws_region))))}"
  
  instance_type = "${var.aws_instance_type}"
  ami = "${lookup(var.ami, "${var.aws_region}-${var.linux_distro_name}-${var.linux_distro_version}")}"
  
  iam_instance_profile = "${aws_iam_instance_profile.iam_instance_profile.id}"
  vpc_security_group_ids = [ "${aws_security_group.sg.id}" ]
  subnet_id = "${element(aws_subnet.instances.*.id, count.index)}"
  associate_public_ip_address = "true"
  ipv6_address_count = 1
  
  key_name = "${aws_key_pair.ssh_key.key_name}"

  connection {
    user = "ubuntu"
    key_file = "${var.ssh_key_path}"
  }

  tags {
    Name = "${var.Project}-${var.Lifecycle}-relay-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
    
  root_block_device {
    volume_type = "standard"
    delete_on_termination = true
    volume_size = "${var.ebs_root_volume_size}"
  }

  volume_tags {
    Name = "${var.Project}-${var.Lifecycle}-relay-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
  user_data = "${element(data.template_cloudinit_config.relay.*.rendered, count.index)}"
}

/* Prepare the user-data for EXIT */

# Render a part using a `template_file`
data "template_file" "exit" {
  count = "${var.tor_exit_count}"

  template = "${file("tor-vpin.sh")}"

  vars {
    role = "EXIT"
    index = "${count.index}"
    ip = ""
    hostname = "exit${count.index}"
    da_hosts = "${join(",", aws_eip.da.*.public_ip)}"
    bridge_hosts = "${join(",", aws_eip.bridge.*.public_ip)}"
    tor_daport = "${var.tor_daport}"
    tor_orport = "${var.tor_orport}"
    s3_bucket = "${var.s3_bucket}"
  }
}

# Render a multi-part cloudinit config making use of the part
# above, and other source files
data "template_cloudinit_config" "exit" {
  count = "${var.tor_exit_count}"

  gzip          = true
  base64_encode = true

  # Setup hello world script to be called by the cloud-config
  part {
    content_type = "text/x-shellscript"
    content      = "${element(data.template_file.exit.*.rendered, count.index)}"
  }
}

/* Create TOR EXIT role instances */

resource "aws_instance" "exit" {
  count = "${var.tor_exit_count}"
    
  availability_zone = "${element(split(",",lookup(var.aws_availability_zones, var.aws_region)), count.index % length(split(",",lookup(var.aws_availability_zones, var.aws_region))))}"
  
  instance_type = "${var.aws_instance_type}"
  ami = "${lookup(var.ami, "${var.aws_region}-${var.linux_distro_name}-${var.linux_distro_version}")}"
  
  iam_instance_profile = "${aws_iam_instance_profile.iam_instance_profile.id}"
  vpc_security_group_ids = [ "${aws_security_group.sg.id}" ]
  subnet_id = "${element(aws_subnet.instances.*.id, count.index)}"
  associate_public_ip_address = "true"
  ipv6_address_count = 1
  
  key_name = "${aws_key_pair.ssh_key.key_name}"

  connection {
    user = "ubuntu"
    key_file = "${var.ssh_key_path}"
  }

  tags {
    Name = "${var.Project}-${var.Lifecycle}-exit-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
    
  root_block_device {
    volume_type = "standard"
    delete_on_termination = true
    volume_size = "${var.ebs_root_volume_size}"
  }

  volume_tags {
    Name = "${var.Project}-${var.Lifecycle}-exit-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
  user_data = "${element(data.template_cloudinit_config.exit.*.rendered, count.index)}"
}

/* Prepare the user-data for BRIDGE */

# Render a part using a `template_file`
data "template_file" "bridge" {
  count = "${var.tor_bridge_count}"

  template = "${file("tor-vpin.sh")}"

  vars {
    role = "BRIDGE"
    index = "${count.index}"
    ip = "${element(aws_eip.bridge.*.public_ip, count.index)}"
    hostname = "bridge${count.index}"
    da_hosts = "${join(",", aws_eip.da.*.public_ip)}"
    bridge_hosts = "${join(",", aws_eip.bridge.*.public_ip)}"
    tor_daport = "${var.tor_daport}"
    tor_orport = "${var.tor_orport}"
    s3_bucket = "${var.s3_bucket}"
  }
}

# Render a multi-part cloudinit config making use of the part
# above, and other source files
data "template_cloudinit_config" "bridge" {
  count = "${var.tor_bridge_count}"

  gzip          = true
  base64_encode = true

  # Setup hello world script to be called by the cloud-config
  part {
    content_type = "text/x-shellscript"
    content      = "${element(data.template_file.bridge.*.rendered, count.index)}"
  }
}

/* Create TOR BRIDGE role instances */

resource "aws_instance" "bridge" {
  count = "${var.aws_instance_count}"
    
  availability_zone = "${element(split(",",lookup(var.aws_availability_zones, var.aws_region)), count.index % length(split(",",lookup(var.aws_availability_zones, var.aws_region))))}"
  
  instance_type = "${var.aws_instance_type}"
  ami = "${lookup(var.ami, "${var.aws_region}-${var.linux_distro_name}-${var.linux_distro_version}")}"
  
  iam_instance_profile = "${aws_iam_instance_profile.iam_instance_profile.id}"
  vpc_security_group_ids = [ "${aws_security_group.sg.id}" ]
  subnet_id = "${element(aws_subnet.instances.*.id, count.index)}"
  associate_public_ip_address = "true"
  ipv6_address_count = 1
  
  key_name = "${aws_key_pair.ssh_key.key_name}"

  connection {
    user = "ubuntu"
    key_file = "${var.ssh_key_path}"
  }

  tags {
    Name = "${var.Project}-${var.Lifecycle}-bridge-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
    
  root_block_device {
    volume_type = "standard"
    delete_on_termination = true
    volume_size = "${var.ebs_root_volume_size}"
  }

  volume_tags {
    Name = "${var.Project}-${var.Lifecycle}-bridge-${count.index}"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
  user_data = "${element(data.template_cloudinit_config.bridge.*.rendered, count.index)}"
}

resource "aws_s3_bucket" "bucket" {

  region   = "${var.aws_region}"
  bucket = "${var.s3_bucket}"
  acl    = "private"

  tags {
    Name = "${var.Project}-${var.Lifecycle}-s3-config"
    Project = "${var.Project}"
    Lifecycle = "${var.Lifecycle}"
  }
}

resource "aws_iam_policy" "iam_policy" {
    name = "${var.Project}-${var.Lifecycle}-instance_policy"
    path = "/"
    description = "Platform IAM Policy"
    policy = <<EOF
{
  "Version": "2012-10-17",
  "Id": "SOFWERXTORVPINBUCKETPOLICY",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["${aws_s3_bucket.bucket.arn}"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": ["${aws_s3_bucket.bucket.arn}/*"]
    }
  ]
}
EOF
}

data "aws_iam_policy_document" "lock_it_down" {
  statement {
    sid = "AllowReadFromVPC"
    effect = "Allow"
    principals {
      type = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ],
    resources = [
      "${aws_s3_bucket.bucket.arn}",
      "${aws_s3_bucket.bucket.arn}/*"
    ]
    condition {
      test = "StringEquals"
      variable = "aws:sourceVpc"
      values = ["${aws_vpc.vpc.id}"]
    }
  }
}

resource "aws_s3_bucket_policy" "bucket" {
  bucket = "${aws_s3_bucket.bucket.bucket}"
  policy = "${data.aws_iam_policy_document.lock_it_down.json}"
}

resource "aws_iam_policy_attachment" "iam_policy_attachment" {
  name = "${var.Project}-${var.Lifecycle}-policy_attach"
  roles = ["${aws_iam_role.iam_role.name}"]
  policy_arn = "${aws_iam_policy.iam_policy.arn}"
}

output "da_ipv4" {
  value = "${join(",", aws_eip.da.*.public_ip)}"
}

output "da_ipv6" {
  value = "${join(",", flatten(aws_instance.da.*.ipv6_addresses))}"
}

output "relay_ipv4" {
  value = "${join(",", aws_instance.relay.*.public_ip)}"
}

output "relay_ipv6" {
  value = "${join(",", flatten(aws_instance.relay.*.ipv6_addresses))}"
}

output "exit_ipv4" {
  value = "${join(",", aws_instance.exit.*.public_ip)}"
}

output "exit_ipv6" {
  value = "${join(",", flatten(aws_instance.exit.*.ipv6_addresses))}"
}

output "bridge_ipv4" {
  value = "${join(",", aws_eip.bridge.*.public_ip)}"
}

output "bridge_ipv6" {
  value = "${join(",", flatten(aws_instance.bridge.*.ipv6_addresses))}"
}

