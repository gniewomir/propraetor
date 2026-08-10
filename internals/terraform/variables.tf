variable "host_root_ssh_public_key" {
  type        = string
  default     = ""
  description = "SSH public key for root Host login via IHP. Apply sets TF_VAR_host_root_ssh_public_key from Operator Configuration; unused when Recreatables are absent."
}

variable "environments_root" {
  type        = string
  default     = ""
  description = "Absolute Environments root (directory of <slug>/ trees). Apply/Park/Teardown set TF_VAR_environments_root from Operator Configuration (ADR-0051). Empty → Stack-relative ../../environments."
}

variable "host_image" {
  type        = string
  default     = "ubuntu-26-04-x64"
  description = "Host Image slug. Lifecycle Tests may override for Recreatable fault injection."
}

variable "recreatables_present" {
  type        = bool
  default     = true
  description = "Operator lifecycle intent: Apply uses the default presence; Park supplies false for that invocation."
}

variable "allow_durable_destroy" {
  type        = bool
  default     = false
  description = <<-EOT
    Teardown only: allow destroying all Durables.
    Default false. Terraform cannot interpolate lifecycle.prevent_destroy, so Teardown
    must also write the Durable module override before destroy and remove it afterward.
    Raw destroy without both stays fail-closed.
  EOT
}
