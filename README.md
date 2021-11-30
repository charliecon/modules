## webserver_cluster
### Example Usage
~~~
module "webserver_cluster" {
    source = "github.com/charliecon/modules//services/webserver-cluster?ref=v0.0.1"

    cluster_name           = "<your-cluster-name>"
    db_remote_state_bucket = "<s3-bucket-name-for-db>"
    db_remote_state_key    = "path/to/db/tf/state/files"
    db_remote_state_region = "us-east-2"

    instance_type = "t2.micro"
    min_size      = 2
    max_size      = 10
}
~~~
### Outputs
- `alb_dns_name` - The domain name of the load balancer
- `asg_name` - The name of the Auto Scaling Group
