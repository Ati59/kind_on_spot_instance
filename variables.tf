variable "trigram" {
  type = string
  description = "Trigram that identify you :)"
}

variable "subnet_id" {
  type = string
  description = "The subnet you want the spot instance created into."
}

variable "standard_tags" {
  type = map
  description = "List of tags to add to every resources created."
}

variable "ssh_public_key_path" {
  type = string
  description = "The public part of the key pair you want to use to login using SSH."
}

variable "spot_bet" {
  type = string
  description = "Maximum value you are welling to pay for this VM."
}

variable "instance_type" {
  type = string
  description = "The size of the spot instance you want to loan."
}
