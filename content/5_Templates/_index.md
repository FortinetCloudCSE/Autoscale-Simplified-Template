---
title: "Templates"
chapter: false
menuTitle: "Templates"
weight: 40
---

#### Existing VPC Resources

The FortiGate Autoscale Simplified Template is designed to attach to an existing customer TGW that may have one or multiple "spoke VPC's". These spoke VPC's may have existing resources that run some sort of workloads that generate egress traffic to the public internet (North-South) or traffic that passes between spoke VPC's (East-West) that may or may not need inspection before being allowed to pass between spoke VPC's. If no firwall inspection is needed for a given workload, then the TGW route tables can be configured to route the traffic directly between the spoke VPC's. If inspection is needed, then the traffic can be routed to the FortiGate Autoscale Group for inspection. 

The "existing_vpc_resources" template is a template that creates the resources described above and can be used to create demo or testing resources to generate test traffic when testing the Autoscale templates in non-production environments. This template can conditionally create the following resources:

![Existing Resources_Diagram](existing-resources-diagram.png)

To use this template, you will need to clone the following repository used for the content of this USE CASE: [FortiGate Simpliefied Autoscale Templates](https://github.com/FortinetCloudCSE/Autoscale-Simplified-Template.git)

After the repository is cloned, navigate to the "Autoscale-Simplified-Template/terraform/existing_vpc_resources" directory and copy the terraform.tfvars.example file to terraform.tfvars. 

![Clone_Repository](clone-repository.png)

Edit the terraform.tfvars file and provide values for the variables as needed.

Fill in the **aws_region** and **availability_zones** you would like to deploy in:

![Region and AZ](region-az.png)

Fill in the **cp** and **env** variables. The values for these variables will be prepended to all resources created by the template.

![customer prefix and environment](cp-env.png)
![customer prefix and environment example](cp-env-example.png)

**enable_build_existing_subnets** is a boolean that allows the template to create subnets/vpc and all resources needed to make the east and west spoke vpcs.

![Existing Subnets](build-existing-subnets.png)

**enable_build_management_vpc** is a boolean that allows the template to create the management vpc.

![Management VPC](build-management-vpc.png)

The following variables allow the conditional creation of a FortiManager and/or FortiAnalyzer in the Management VPC. If the variables are set to true, you can then specify the instance type, FortiOS version, host portion of the IP address, and attach a license to the instance. 

![FortiManager and FortiAnalyzer Options](faz-fmgr-options.png)

Optionally attach to the existing_vpc TGW. This allows instances in the management vpc to connect to spoke vpc instances. Specify the TAG Name of the existing vpc TGW. This is useful for testing. 

![Management VPC TGW Attachment](mgmt-attach-tgw.png)

CIDR's for the management and spoke vpc subnets.

![Management Spoke CIDRs](mgmt-spoke-cidrs.png)

Enable the creation and instance type of the various management and spoke vpc linux instances. Refer to the diagram to see where these instances are placed. 

![Linux Instances](linux-instances.png)

#### Simplified Autoscale Template


Edit the terraform.tfvars file and provide values for the variables as needed.

Fill in the **aws_region** and **availability_zones** you would like to deploy in:

![Region and AZ](region-az.png)

Fill in the **cp** and **env** variables. The values for these variables will be prepended to all resources created by the template.

![customer prefix and environment](cp-env.png)
![customer prefix and environment example](cp-env-example.png)

**keypair** is the name of the keypair that will be used to create the EC2 instances. This keypair must exist in the region you are deploying to.
**my_ip** is the public IP used to create a security group that restricts access to those resources exposed to the public internet. 
**fortigate_asg_password** is the password that will be used to access the FortiGate instances for user **admin**.

![security variables](security.png)

**enable_tgw_attachment** is a boolean variable that will attach the Inspection VPC to the named TGW.  

![TGW Attachment](tgw_attachment.png)

**attach_to_tgw_name** is the name of the TGW that the Inspection VPC will attach to. The default is the name of the TGW created by the existing_vpc_resources template.

![tgw-name.png](tgw-name.png)

#### asg_license_directory and FortiFlex licensing

See the Licensing section for a complete licensing discussion

![License Variables](license-variables.png)

Follow the comments to fill in the rest of the variables as needed.

#### Template Deployment

Once the terraform.tfvars variable assignment is complete, you can deploy the template using the following commands:

  ``` terraform init ```

  ``` terraform plan ``` 

  ``` terraform apply ```

* This concludes this section
