# The subnet you want your VM into
# /!\ The VM has to be on a public subnet (with IGW)
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

# A trigram that identify you
trigram = "ati"

# SSH pub key to deploy
ssh_public_key_path = "${YOUR_HOME_HERE}/.ssh/id_rsa.pub"

# Kind of instance you want and its price
instance_type = "t3.2xlarge"
spot_bet = "0.15"

# Tags to deploy on every resources created
standard_tags = {
  created-by = "my_name",
  team       = "my_team",
  purpose    = "test"
  as-code    = true
}
