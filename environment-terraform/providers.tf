provider "azurerm" {
  # Whilst version is optional, we /strongly recommend/ using it to pin the version of the Provider being used
  version = "=2.20.0"
  features {}
}

provider "azuread" {
  version = "=1.0.0"
}

data "azurerm_client_config" "current" {}
