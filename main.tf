
data "aws_subnet" "pub_subnet" {
  id = var.subnet_id
}

data "aws_ami" "debian_11" {
  most_recent = true
  owners = ["amazon"]

  filter {
    name = "name"
    values = ["debian-11-amd64-*"]
  }

  filter {
    name = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name = "architecture"
    values = ["x86_64"]
  }
}

data "template_file" "bootstrap" {
  template = file("${path.module}/misc/userdata.sh")
  vars = {
    s3_bucket_name = aws_s3_bucket.bucket.id
    zip_filename = aws_s3_object.spot_misc.key
  }
}

data "aws_instances" "spot-fleet-ips" {
  depends_on = [
    aws_spot_fleet_request.spot_instance
  ]
  instance_tags = {
    Name = "${var.trigram}-kind-spot-instance"
  }
}

data "http" "home_ip" {
   url = "https://ifconfig.me/ip"
}

data "archive_file" "dotfiles" {
  type        = "zip"
  output_path = "${path.module}/tmp/spot_instance_misc.zip"

  source {
    filename = "kind_lib.sh"
    content = file("misc/lib.sh")
  }
}

# -------------

resource "random_string" "icv" {
  length  = 8
  special = false
  upper   = false
}
resource "aws_s3_bucket" "bucket" {
  bucket = "${var.trigram}-kindspotinstance-${random_string.icv.result}"
  tags = {
    Name = "${var.trigram}-kindspotinstance-${random_string.icv.result}"
  }
}

resource "aws_s3_bucket_acl" "bucket" {
  bucket = aws_s3_bucket.bucket.id
  acl    = "private"
}

resource "aws_s3_bucket_public_access_block" "bucket" {
  bucket = aws_s3_bucket.bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "spot_misc" {
  bucket = aws_s3_bucket.bucket.id
  key    = "spot_instance_misc.zip"
  source = "${path.module}/tmp/spot_instance_misc.zip"
}

resource "aws_security_group" "ingress_ssh" {
  name   = "${var.trigram}-kind_spot_instance-home-only"
  vpc_id = data.aws_subnet.pub_subnet.vpc_id

  # SSH
  ingress {
    cidr_blocks = [
      "${chomp(data.http.home_ip.response_body)}/32"
    ]

    from_port = 22
    to_port   = 22
    protocol  = "tcp"
  }

  # K8S
  ingress {
    cidr_blocks = [
      "${chomp(data.http.home_ip.response_body)}/32"
    ]

    from_port = 7000
    to_port   = 7050
    protocol  = "tcp"
  }

  # OUT
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "spot_key" {
  key_name   = "${var.trigram}-solo-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_spot_fleet_request" "spot_instance" {
  iam_fleet_role       = aws_iam_role.fleet_role.arn
  spot_price           = var.spot_bet
  allocation_strategy  = "lowestPrice"
  target_capacity      = 1
  wait_for_fulfillment = true
  terminate_instances_on_delete = true

  launch_specification {
    ami                      = data.aws_ami.debian_11.image_id
    instance_type            = var.instance_type
    key_name                 = aws_key_pair.spot_key.key_name
    subnet_id                = var.subnet_id
    vpc_security_group_ids   = [aws_security_group.ingress_ssh.id]
    user_data                = data.template_file.bootstrap.rendered
    monitoring               = false
    iam_instance_profile_arn = aws_iam_instance_profile.spots.arn

    root_block_device {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = "true"
    }

    tags = merge(
      { Name = "${var.trigram}-kind-spot-instance" },
      var.standard_tags
    )
  }
}

resource "aws_iam_instance_profile" "spots" {
  name = "${var.trigram}_spots"
  role = aws_iam_role.spots.name
}

data "aws_iam_policy_document" "instance-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "spots" {
  name = "${var.trigram}_spots"
  path = "/"

  assume_role_policy = data.aws_iam_policy_document.instance-assume-role-policy.json
  
  inline_policy {
    name   = "s3_access"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action   = [
            "s3:ListAllMyBuckets"
          ]
          Effect   = "Allow"
          Resource = "*"
        },
        {
          Action   = [
              "s3:ListBucket",
              "s3:GetObject",
              "s3:GetObjectVersion"
          ]
          Effect   = "Allow"
          Resource = [
            "arn:aws:s3:::${aws_s3_bucket.bucket.id}/*",
            "arn:aws:s3:::${aws_s3_bucket.bucket.id}"
          ]
        },
      ]
    })
  }
}

resource "aws_iam_policy" "fleet_policy" {
  name        = "EC2SpotFleetServiceRolePolicy"
  path        = "/"
  description = "Allows EC2 Spot Fleet to launch and manage spot fleet instances"

  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ec2:DescribeImages",
          "ec2:DescribeSubnets",
          "ec2:RequestSpotInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:RunInstances"
        ],
        "Resource": [
          "*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "iam:PassRole"
        ],
        "Resource": [
          "*"
        ],
        "Condition": {
          "StringEquals": {
            "iam:PassedToService": [
              "ec2.amazonaws.com",
              "ec2.amazonaws.com.cn"
            ]
          }
        }
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:CreateTags"
        ],
        "Resource": [
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:spot-instances-request/*",
          "arn:aws:ec2:*:*:spot-fleet-request/*",
          "arn:aws:ec2:*:*:volume/*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:TerminateInstances"
        ],
        "Resource": "*",
        "Condition": {
          "StringLike": {
            "ec2:ResourceTag/aws:ec2spot:fleet-request-id": "*"
          }
        }
      },
      {
        "Effect": "Allow",
        "Action": [
          "elasticloadbalancing:RegisterInstancesWithLoadBalancer"
        ],
        "Resource": [
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "elasticloadbalancing:RegisterTargets"
        ],
        "Resource": [
          "arn:aws:elasticloadbalancing:*:*:*/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "fleet_role" {
  name = "ServiceRoleForEC2SpotFleet"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "spotfleet.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
  })
  managed_policy_arns = [aws_iam_policy.fleet_policy.arn]
}

# -------------

output "spot_public_ip" {
  value = <<COMMANDS
# To be able to create new cluster or to debug
SSH command     : sshr ${data.aws_instances.spot-fleet-ips.public_ips[0]}
Cloud init logs : sshr ${data.aws_instances.spot-fleet-ips.public_ips[0]} tail -f /var/log/cloud-init-output.log

# Tunneling the k8s network throught SSH to get access to services hosted
Shuttle command : screen sshuttle -vvv -e "ssh -v" -r root@${data.aws_instances.spot-fleet-ips.public_ips[0]} 172.18.16.0/20

# To connect directly from your laptop
Kubectl         : scp -R root@${data.aws_instances.spot-fleet-ips.public_ips[0]}:/root/.kube/config /tmp/kube-${data.aws_instances.spot-fleet-ips.public_ips[0]}.config
                  sed -i 's/0.0.0.0/${data.aws_instances.spot-fleet-ips.public_ips[0]}/' /tmp/kube-${data.aws_instances.spot-fleet-ips.public_ips[0]}.config
              
                  # Then you can use it in multiple ways :
1.                export KUBECONFIG=/tmp/kube-${data.aws_instances.spot-fleet-ips.public_ips[0]}.config
2.                alias k="kubectl --kubeconfig /tmp/kube-${data.aws_instances.spot-fleet-ips.public_ips[0]}.config"
                  alias kubectl="kubectl --kubeconfig /tmp/kube-${data.aws_instances.spot-fleet-ips.public_ips[0]}.config"
3.                cp -a ~/.kube/config ~/.kube/config.bak && KUBECONFIG=~/.kube/config:/tmp/kube-${data.aws_instances.spot-fleet-ips.public_ips[0]}.config kubectl config view --flatten > ~/.kube/config
  COMMANDS
}
