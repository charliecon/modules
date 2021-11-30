locals {
    http_port    = 80
    any_port     = 0
    any_protocol = "-1"
    tcp_protocol = "tcp"
    all_ips      = ["0.0.0.0/0"]
}

resource "aws_launch_configuration" "example" {
    image_id           = "ami-0c55b159cbfafe1f0"
    instance_type      = var.instance_type

    # - "Creating the security group isn't enough. We need to
    #    tell the EC2 instance to actually use it by doing this:"
    security_groups = [aws_security_group.instance.id]
    
    # - "When you launch an EC2 instance, you have the option of 
    #   passing either a shell script or cloud-init directive to User Data,
    #   and the EC2 instance will execute it during boot."
    # - "We wrap the busybox command with nohup and '&' so that
    #   the web server runs permanently in the background
    #   whereas the Bash script itself can exit."
    user_data = data.template_file.user_data.rendered

    # Required when using a launch configuration with an auto scaling group
    # https://www.terraform.io/docs/providers/aws/r/launch/_configuration.html
    lifecycle {
        create_before_destroy = true
    }
}


# This ASG is used to launch and manage a cluster of our EC2 Instances
resource "aws_autoscaling_group" "example" {
    launch_configuration = aws_launch_configuration.example.name
    # This param specifies to the ASG into which VPC subnets the
    # EC2 Instances should be deployed.   
    vpc_zone_identifier  = data.aws_subnet_ids.default.ids

    target_group_arns = [aws_lb_target_group.asg.arn]
    health_check_type = "ELB"

    min_size = var.min_size
    max_size = var.max_size

    tag {
        key                 = "Name"
        value               = "${var.cluster_name}-asg"
        propagate_at_launch = true
    }
}

# Create the application load balancer (ALB)
resource "aws_lb" "example" {
    name               = "${var.cluster_name}-asg"
    load_balancer_type = "application"
    subnets            = data.aws_subnet_ids.default.ids
    security_groups    = [aws_security_group.alb.id]
}

# Define our listener to specify the port and protocol 
resource "aws_lb_listener" "http" {
    load_balancer_arn = aws_lb.example.arn
    port              = local.http_port
    protocol          = "HTTP"

    # By default, return a simple 404 page
    default_action {
        type = "fixed-response"

        fixed_response {
            content_type = "text/plain"
            message_body = "404: page not found"
            status_code  = 404
        }
    }
}

# Create the target group for our ASG
resource "aws_lb_target_group" "asg" {
    name     = "terraform-asg-example"
    port     = var.server_port
    protocol = "HTTP"
    vpc_id   = data.aws_vpc.default.id

    health_check {
        path                = "/"
        protocol            = "HTTP"
        matcher             = "200"
        interval            = 15
        timeout             = 3
        healthy_threshold   = 2
        unhealthy_threshold = 2 
    }
}

# Create our listener rules
resource "aws_lb_listener_rule" "asg" {
    listener_arn = aws_lb_listener.http.arn
    priority     = 100

    condition {
        path_pattern {
            values = ["*"]
        }
    }

    action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.asg.arn
    }
}

# - "This resource specifies that this group allows incoming TCP requests
#    on port 8080 from any IP."
# - "By default, AWS does not allow any incoming or outgoing traffic
#    from an EC2 instance. To allow the EC2 Instance to receive traffic
#    on port 8080, you need to create a security group:"
resource "aws_security_group" "instance" {
    name = "${var.cluster_name}-instance"

    ingress {
        from_port   = var.server_port
        to_port     = var.server_port
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

# - "All AWS resources, including ALBs, don't allow any incoming or outgoing
#    traffic, so you need to create a new security group specifically for the
#    ALB. 
#    Incoming requests so you can access the load balancer over HTTP.
#    Outgoing requests on all ports so that the load balancer can perform health checks."
resource "aws_security_group" "alb" {
    name = "${var.cluster_name}-alb"
}

# Incoming requests so you can access the load balancer over HTTP.
resource "aws_security_group_rule" "allow_http_inbound" {
    type              = "ingress"
    security_group_id = aws_security_group.alb.id

    from_port   = local.http_port
    to_port     = local.http_port
    protocol    = local.tcp_protocol
    cidr_blocks = local.all_ips 
}

# Outgoing requests on all ports so that the load balancer can perform health checks."
resource "aws_security_group_rule" "allow_all_outbound" {
    type              = "egress"
    security_group_id = aws_security_group.alb.id

    from_port   = local.any_port
    to_port     = local.any_port
    protocol    = local.any_protocol
    cidr_blocks = local.all_ips 
}

# - "A data source represents a piece of read-only info that is fetched from
#    the provider."
# - "With data sources, the arguments you pass in are typically search filters
#    that indicate to the data source what info you're looking for."
# - "With the aws_vpc data source, the only filter we need is 'default = true',
#    which directs Terraform to look up the Default VPC in your AWS account."
data "aws_vpc" "default" {
    default = true
}

data "aws_subnet_ids" "default" {
    vpc_id = data.aws_vpc.default.id
}

# This data source allows for read-only access to remote state files 
# created by other configurations. Through this, we can easily access
# output attributes in the form: data.terraform_remote_state.<NAME>.outputs.<ATTRIBUTE>
data "terraform_remote_state" "db" {
    backend = "s3"

    config = {
        bucket = var.db_remote_state_bucket 
        key    = var.db_remote_state_key 
        region = var.db_remote_state_region
    }
}

data "template_file" "user_data" {
    template = file("${path.module}/user-data.sh")

    vars = {
        server_port = var.server_port
        db_address  = data.terraform_remote_state.db.outputs.address
        db_port     = data.terraform_remote_state.db.outputs.port
    }
}
