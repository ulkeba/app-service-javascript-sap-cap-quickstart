# This script is part of the sample's workflow for configuring the Azure CosmosDB connection
# string on the App Service, create the App Registrations in Entra ID, saving the appropriate
# values in Key Vault, and Azure App Config Service.
# Note that an app registration is something you'll want to set up once, and reuse for every version
# of the web app that you deploy. You can learn more about app registrations at
# https://learn.microsoft.com/azure/active-directory/develop/application-model
#
# If you do not have permission to create App Registrations consider
# sharing this script, or something similar, with your administrators to help them
# set up the variables you need to integrate with Azure AD
#
# This code may be repurposed for your scenario as desired
# but is not covered by the guidance in this content.

# Using Azure CLI command to create an app registration on Entra ID: https://learn.microsoft.com/cli/azure/ad/app?view=azure-cli-latest
# and https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-provider-aad?tabs=workforce-tenant

try {
    # This script section is used to inject the Cosmos DB connection string into the Azure App Service configuration after AZD deployment.
    # It requires the Azure CLI to be installed, configured on the build agent, and logged in interactively or via a service principal.
    $serverName = "$env:COSMOSDB_CLUSTER_NAME-c"

    Write-Output "Retrieving CosmosDB for PSQL (citus) FQDN..."
    # Call cosmos DB API to get the FQDN to compose the connection string
    $CosmosDBMetadata = az cosmosdb postgres cluster server show --server-name $serverName --cluster-name $env:COSMOSDB_CLUSTER_NAME --resource-group $env:RESOURCE_GROUP_NAME --subscription $env:AZURE_SUBSCRIPTION_ID | ConvertFrom-Json
    $FQDN = $CosmosDBMetadata.fullyQualifiedDomainName

    Write-Output "Storing CosmosDB for PSQL (citus) FQDN as POSTGRES_HOSTNAME in azure app settings..."
    # Store the FQDN on the Azure App Service configuration as normal key value pair
    az webapp config appsettings set --name $env:WEB_APP_NAME --resource-group $env:RESOURCE_GROUP_NAME --settings POSTGRES_HOSTNAME=$FQDN --subscription $env:AZURE_SUBSCRIPTION_ID

    Write-Output "Retrieving CosmosDB for PSQL (citus) admin password..."
    # Read Cosmos DB admin password from the Azure Key Vault
    $KeyVaultSecret = az keyvault secret show --name $env:AZURE_KEY_VAULT_COSMOS_SECRET_NAME --vault-name $env:AZURE_KEY_VAULT_NAME | ConvertFrom-Json
    # Regular expression pattern to match special characters in CosmosDBpwd String
    $Pattern = "([\.\^\$\*\+\?\{\}\[\]\\\|\(\)])"
    $CosmosDBpwd = $KeyVaultSecret.value -replace $Pattern, '`$1'

    # Compose the connection string
    $connectionString = "postgres://citus:${CosmosDBpwd}@${FQDN}:5432/citus?sslmode=require"
    # Regular expression pattern to match special characters in CosmosDBpwd String, especially pipe, ^, {} and $.
    $Pattern = "([\.\^\$\*\+\?\{\}\[\]\\\|\(\)])"
    # Encapsulating special characters in the connection string with double quotes to avoid interpretation by Azure CLI
    $connectionString = $connectionString -replace $Pattern, '"$1"'

    Write-Output "Injecting CosmosDB for PSQL (citus) connection string into the Azure App Service configuration..."
    # Inject the connection string into the Azure App Service configuration as normal key value pair
    #az webapp config appsettings set --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP_NAME --settings COSMOSDB_CONNECTION_STRING=$connectionString --subscription $AZURE_SUBSCRIPTION_ID
    # Inject the connection string into the Azure App Service configuration https://learn.microsoft.com/cli/azure/webapp/config/connection-string?view=azure-cli-latest
    az webapp config connection-string set --resource-group $env:RESOURCE_GROUP_NAME --name $env:WEB_APP_NAME -t postgresql --settings psql1=$connectionString --subscription $env:AZURE_SUBSCRIPTION_ID

    if ($env:USE_EntraIDAuthentication -eq "false") {

        Write-Output "Skipping app registration creation because USE_EntraIDAuthentication is set to false"
        Write-Output "Done."
        exit 0

    } else {

        #Ensure Authv2 extension is installed. See https://learn.microsoft.com/en-us/cli/azure/webapp/auth/microsoft?view=azure-cli-latest
        az config set extension.use_dynamic_install=yes_without_prompt
        
        #Calculate redirect uri for web app using Entra ID authentication
        $redirectUri = "https://${env:WEB_APP_NAME}.azurewebsites.net/.auth/login/aad/callback"
        
        # In case web app shall be authorized to call SAP OData api via Azure APIM 
        $APIM_API_SCOPES_JSON_ROOT = @()
        $APIM_API_SCOPES_JSON_LIST = @()
        $APIM_API_METADATA = $null
        if($env:AZURE_APIM_APP_ID -ne ''){
            Write-Output "Reading Azure APIM app registration metadata..."
            #Read scopes array from Azure APIM app registration
            $APIM_API_METADATA = az ad app show --id $env:AZURE_APIM_APP_ID | ConvertFrom-Json
            if (!$APIM_API_METADATA) {
                Write-Error "Error reading Azure APIM app registration metadata. Ensure AZURE_APIM_APP_ID is set correctly. Trace: $_"
                exit 1
            }
            #See the JSON structure of 'oauth2PermissionScopes' etc via: az ad app show --id <entra-id-app-id>
            $APIM_API_SCOPES = $APIM_API_METADATA.api.oauth2PermissionScopes

            #Loop $APIM_API_SCOPES and create a json array of json objects for each scope
            foreach($scope in $APIM_API_SCOPES){
                $APIM_API_SCOPES_JSON_LIST += @{
                    id = $scope.id
                    type = "Scope"
                }
            }
            $APIM_API_SCOPES_JSON_ROOT += @{
                resourceAppId = $env:AZURE_APIM_APP_ID
                resourceAccess = $APIM_API_SCOPES_JSON_LIST
            }
            #Always add standard Microsoft Graph User.Read scope to the array
            $APIM_API_SCOPES_JSON_ROOT += @{
                resourceAppId = "00000003-0000-0000-c000-000000000000"
                resourceAccess = @(
                    @{
                        id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
                        type = "Scope"
                    }
                )
            }
        }
        else{
            Write-Output "Skipping web app authorization to Azure APIM app registration because AZURE_APIM_APP_ID is not set"
        }
        #Compose aad app registration config supporting AUTH v2 https://learn.microsoft.com/graph/api/application-post-applications?view=graph-rest-1.0&tabs=http#response-1
        #Access token version 2 is required
        $appRegistrationConfig = (@{
            displayName = $env:WEB_APP_NAME
            signInAudience = "AzureADMyOrg"
            api = @{
                requestedAccessTokenVersion = 2
            }
            requiredResourceAccess = $APIM_API_SCOPES_JSON_ROOT
            web = @{
                redirectUris = @($redirectUri)
                implicitGrantSettings = @{
                    enableIdTokenIssuance = "true"
                }
            }
        } | ConvertTo-Json -Depth 7 -Compress).Replace('"', '\"')

        Write-Output "Creating web app Entra ID app registration..."
        $APP_REG_METADATA = az rest --method POST `
                                    --headers "{'Content-Type':'application/json'}" `
                                    --uri "https://graph.microsoft.com/v1.0/applications" `
                                    --body $appRegistrationConfig | ConvertFrom-Json
        if(!$APP_REG_METADATA){
            Write-Error "Error creating web app Entra ID app registration for your web app. Trace: $_"
            exit 1
        }
        $OBJECT_ID = $APP_REG_METADATA.id
        $CLIENT_ID = $APP_REG_METADATA.appId
        
        Write-Output "Generating secret for app registration..."
        # Create secret for app registration
        $NEW_CREDENTIAL = az ad app credential reset --id $OBJECT_ID `
                                                     --append `
                                                     --display-name 'Generated by AZD' | ConvertFrom-Json
        if(!$NEW_CREDENTIAL){
            Write-Error "Error generating secret for app registration. Trace: $_"
            exit 1
        }

        $SECRET = $NEW_CREDENTIAL.password

        Write-Output "Storing app registration secret in key vault..."
        #Store secret in key vault
        $STORE_CMD = az keyvault secret set --vault-name $env:AZURE_KEY_VAULT_NAME `
                                            --name $env:AAD_KV_SECRET_NAME `
                                            --value $SECRET | ConvertFrom-Json
        if(!$STORE_CMD){
            Write-Error "Error storing app registration secret in key vault. Trace: $_"
            exit 1
        }

        Write-Output "Adding Authentication settings to Azure App Service..."
        $audiences = "api://${CLIENT_ID}" #comma delimited list of audiences
        $ISSUER_URL = "https://login.microsoftonline.com/${env:AZURE_TENANT_ID}/v2.0"

        $authSettingsJson = (@{
            globalValidation = @{
                redirectToProvider = "azureActiveDirectory"
                requireAuthentication = "true"
                unauthenticatedClientAction = "RedirectToLoginPage"
            }
            identityProviders = @{
                azureActiveDirectory = @{
                    enabled = "true"
                    registration = @{
                       clientId = $CLIENT_ID
                       clientSecretSettingName = $env:AAD_KV_SECRET_NAME
                       openIdIssuer = $ISSUER_URL
                    }
                    validation = @{ 
                        allowedAudiences = @($audiences)
                    }
                }
            }
            login = @{
                tokenStore = @{
                    enabled = "true"
                }
            }
            platform = @{
                enabled = "true"
            }
        } | ConvertTo-Json -Depth 4 -Compress).Replace('"', '\"')

        Write-Output "Setting the authentication settings for the webapp in the v2 format, overwriting any existing settings..."
        
        #https://learn.microsoft.com/cli/azure/webapp/auth/config-version?view=azure-cli-latest#az-webapp-auth-config-version-upgrade
        #https://learn.microsoft.com/cli/azure/webapp/auth?view=azure-cli-latest#az-webapp-auth-set
        $AUTH_SET_CMD = az webapp auth set --name $env:WEB_APP_NAME `
                                           --resource-group $env:RESOURCE_GROUP_NAME `
                                           --subscription $env:AZURE_SUBSCRIPTION_ID `
                                           --body $authSettingsJson | ConvertFrom-Json
        if(!$AUTH_SET_CMD){
            Write-Error "Error setting the authentication settings for the webapp in the v2 format. Trace: $_"
            exit 1
        }

        # In case web app shall be authorized to call SAP OData api via Azure APIM 
        if($env:AZURE_APIM_APP_ID -ne ''){
            Write-Output "Adding web app registration as pre-authorized client to the Azure APIM app registration..."
            #Compose PATCH request to add the web app as pre-authorized client to the Azure APIM app registration
            
            $delegatedPermissions = @()
            foreach($scope in $APIM_API_SCOPES){
                #Skip the Microsoft Graph User.Read scope
                if($scope.id -eq "e1fe6dd8-ba31-4d61-89e7-88639da4683d"){
                    continue
                }
                #Add ids of Azure APIM exposed API scopes to delegate permission to the web app and pre-authorize
                $delegatedPermissions += @($scope.id)
            }

            $APIM_API_METADATA.api.preAuthorizedApplications += @(
                @{
                    appId = $CLIENT_ID
                    delegatedPermissionIds = $delegatedPermissions
                }
            )
            #Write-Output $APIM_API_METADATA.api

            $preAuthorizedWebAppsSection = (@{
                api = @{
                    preAuthorizedApplications = $APIM_API_METADATA.api.preAuthorizedApplications
                }
            } | ConvertTo-Json -Depth 4 -Compress).Replace('"', '\"')

            #Inject the azure web app as pre-authorized client to the Azure APIM app registration using object id
            $AZURE_APIM_APP_METADATA = az ad app show --id $env:AZURE_APIM_APP_ID | ConvertFrom-Json
            $APIM_APP_OBJECT_ID = $AZURE_APIM_APP_METADATA.id

            $URI = "https://graph.microsoft.com/v1.0/applications/${APIM_APP_OBJECT_ID}"
            Write-Output $URI
            az rest --method PATCH `
                    --headers "{'Content-Type':'application/json'}" `
                    --uri $URI `
                    --body $preAuthorizedWebAppsSection
            
            Write-Output "Asynch App registration finished. Check log for status code 204. Consider --debug flag. Trace: $_"
        }else{
            Write-Output "Skipping pre-authorizing web app on Azure APIM app registration because AZURE_APIM_APP_ID is not set"
        }

        Write-Output "done"
        # all done
        exit 0
    }
} catch {
    Write-Error "An error occurred: $_"
    exit 1
}
