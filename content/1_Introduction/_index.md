---
title: "Introduction"
menuTitle: "Introduction"
weight: 10

---

![Example Diagram](asg-template.png)

## Welcome

The purpose of this site is to provide documentation on how to use the FortiGate Autoscale Simplified Template. The actual templates that are used to deploy a FortiGate Autoscale Group are located here: [FortiGate Autoscale Templates](https://github.com/fortinetdev/terraform-aws-cloud-modules). While these templates are very powerful, they are somewhat cryptic to configure, and they use a very strict syntax for deploying the desired architecture. The "Simplified Template" is a "wrapper" template that will deploy a FortiGate Autoscale Group in a few of our most common use-case scenarios, simply by answering a few True/False boolean variables and providing paths and parameters for commonly configured autoscale items. These items include, subnetting parameters, autoscale capacity parameters, license directories, etc. 

For other documentation needs such as FortiOS administration, please reference [docs.fortinet.com](https://docs.fortinet.com/). 