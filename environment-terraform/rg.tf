resource "azurerm_resource_group" "main" {
  name     = var.resource_group
  location = var.location
}

resource "azurerm_key_vault_secret" "env_rg" {
  name         = "ENVIRONMENT-RESOURCE-GROUP-NAME"
  value        = azurerm_resource_group.main.name
  key_vault_id = azurerm_key_vault.keyvault.id

  depends_on = [
    azurerm_key_vault_access_policy.keyvault
  ]
}
