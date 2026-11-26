# Shared backend settings; each env passes its own `key`.
resource_group_name  = "rg-ridenest-ilc"
storage_account_name = "stridenesttfc7f28b"
container_name       = "tfstate"
use_azuread_auth     = true
