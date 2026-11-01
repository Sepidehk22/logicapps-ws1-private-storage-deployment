# Deployment di Logic Apps Standard WS1 con storage privato

## 1. Verificare i prerequisiti

1. Selezionare una subscription Azure public cloud e una regione con quota e disponibilita' per Logic Apps Standard Windows WS1. Approvare il costo delle risorse.
2. Verificare la registrazione dei provider `Microsoft.Web`, `Microsoft.Storage`, `Microsoft.Network`, `Microsoft.Insights`, `Microsoft.OperationalInsights` e `Microsoft.ManagedIdentity`.
3. Verificare che le policy consentano WS1, Private Endpoint e Shared Key sullo storage. Non procedere se Shared Key e' vietata: il runtime e la content share Azure Files richiedono questa configurazione. Limitare l'accesso alle chiavi e agli app settings; l'abilitazione Shared Key vale per l'intero account.
4. Riservare un nuovo resource group, una nuova VNet senza sovrapposizioni, una subnet integration dedicata /26 o maggiore e una subnet distinta per i Private Endpoint.
5. Identificare uno o due DNS privati raggiungibili e un forwarder DNS in Azure oppure un inbound endpoint di Azure DNS Private Resolver. Verificare che le VNet resolver possano essere collegate alle zone Private DNS senza conflitti. In presenza di zone centralizzate o AMPLS esistente, adattare i template per riutilizzarli prima del deployment.
6. Preparare un client Windows amministrativo con PowerShell 7, Azure CLI e Git. Predisporre accesso privato alla VNet, ai DNS e ai servizi da controllare, oltre all'accesso HTTPS ad Azure ed Entra.
7. Ottenere i permessi per creare le risorse, collegare le VNet resolver alle zone DNS, eseguire `listKeys` sullo storage e assegnare Monitoring Metrics Publisher alla managed identity su Application Insights. Usare permessi di pubblicazione separati, limitati alla Logic App.

Non inserire chiavi, token o connection string nei file. Non abilitare transcript o logging di debug durante il deployment e non condividere output contenenti configurazione sensibile.

## 2. Scaricare i file e selezionare la subscription

Eseguire i comandi seguenti in PowerShell. Sostituire tutti i segnaposto prima dell'esecuzione e mantenere la stessa sessione per i passaggi successivi.

```powershell
git clone https://github.com/Sepidehk22/logicapps-ws1-private-storage-deployment.git
if ($LASTEXITCODE -ne 0) { throw 'Download del repository non riuscito' }
Set-Location .\logicapps-ws1-private-storage-deployment

$subscription = '<subscription-id>'
$rg = '<nuovo-resource-group>'
$location = '<regione-approvata>'

az login
if ($LASTEXITCODE -ne 0) { throw 'Login non riuscito' }
az account set --subscription $subscription
if ($LASTEXITCODE -ne 0) { throw 'Subscription non selezionata' }
```

## 3. Compilare i parametri

Creare le copie locali dei file di esempio:

```powershell
Copy-Item .\infra\foundation.parameters.example.json .\infra\foundation.parameters.local.json -ErrorAction Stop
Copy-Item .\infra\application.parameters.example.json .\infra\application.parameters.local.json -ErrorAction Stop
```

Modificare i due file locali usando i valori seguenti:

| Parametro | Valore da inserire |
|---|---|
| `environmentName` | Identificativo stabile, uguale nelle due fasi |
| `location` | Regione selezionata, uguale a `$location` |
| `vnetAddressPrefix` | CIDR della nuova VNet |
| `integrationSubnetPrefix` | CIDR della subnet integration, /26 o maggiore |
| `privateEndpointSubnetPrefix` | CIDR della subnet Private Endpoint, senza sovrapposizioni |
| `dnsServerIps` | IPv4 del DNS primario e, se presente, secondario; stessi valori nelle due fasi |
| `resolverVnetResourceIds` | ID delle VNet Azure del forwarder o resolver, senza duplicati e senza la nuova VNet workload |
| `serviceAUrl`, `serviceBUrl` | URL HTTPS dei due health endpoint, con risposta diretta HTTP 200 |

Non inserire credenziali, SAS o API key negli URL. Per endpoint che richiedono autenticazione, configurare esplicitamente l'autenticazione managed identity nelle azioni HTTP e le autorizzazioni sul servizio prima di pubblicare il workflow.

Mantenere invariati resource group, `environmentName`, regione e DNS tra le due fasi. Non pubblicare i file `*.parameters.local.json`.

## 4. Distribuire rete, storage e monitoraggio

Creare il resource group e validare [foundation.json](infra/foundation.json):

```powershell
az group create --name $rg --location $location --output none
if ($LASTEXITCODE -ne 0) { throw 'Creazione del resource group non riuscita' }
az deployment group validate --resource-group $rg --template-file .\infra\foundation.json --parameters '@infra\foundation.parameters.local.json' --output none
if ($LASTEXITCODE -ne 0) { throw 'Validazione della fondazione non riuscita' }
az deployment group what-if --resource-group $rg --template-file .\infra\foundation.json --parameters '@infra\foundation.parameters.local.json'
if ($LASTEXITCODE -ne 0) { throw 'What-if della fondazione non riuscito' }
```

Esaminare il what-if sul client autorizzato. Approvare solo le risorse e i collegamenti DNS previsti, quindi eseguire:

```powershell
az deployment group create --resource-group $rg --name ws1-foundation --template-file .\infra\foundation.json --parameters '@infra\foundation.parameters.local.json' --output none
if ($LASTEXITCODE -ne 0) { throw 'Deployment della fondazione non riuscito' }
$namesJson = az deployment group show --resource-group $rg --name ws1-foundation --query properties.outputs.resourceNames.value --output json
if ($LASTEXITCODE -ne 0) { throw 'Lettura degli output non riuscita' }
$names = $namesJson | ConvertFrom-Json -ErrorAction Stop
$storage = $names.storage
```

Nel portale Azure verificare:

- Subnet integration delegata a `Microsoft.Web/serverFarms`, separata dai Private Endpoint.
- Storage con public network access `Disabled`, anonymous blob access disabilitato, firewall `Deny`, bypass `None`, HTTPS e TLS 1.2.
- File share `logicapp-content` presente.
- Private Endpoint Blob, File, Queue, Table e Monitor con connessioni `Approved`.
- Zone Private DNS collegate alla VNet workload e alle VNet resolver selezionate.
- Managed identity con Monitoring Metrics Publisher su Application Insights.

Non abilitare accesso pubblico allo storage, neppure temporaneamente.

## 5. Configurare DNS e connettivita' privata

1. Configurare peering, VPN o ExpressRoute e le route necessarie tra la VNet creata, il client amministrativo, i DNS e i servizi di destinazione.
2. Consentire DNS TCP/UDP 53, storage HTTPS 443, Azure Files SMB 445 e app/SCM HTTPS 443. Consentire anche le dipendenze di piattaforma e monitoraggio necessarie attraverso il percorso di uscita approvato.
3. Sul DNS utilizzato dal client e dalla Logic App, configurare conditional forwarding dei domini seguenti verso il forwarder Azure o l'inbound endpoint del resolver:

| Dominio da inoltrare | Zona Private DNS |
|---|---|
| `blob.core.windows.net` | `privatelink.blob.core.windows.net` |
| `file.core.windows.net` | `privatelink.file.core.windows.net` |
| `queue.core.windows.net` | `privatelink.queue.core.windows.net` |
| `table.core.windows.net` | `privatelink.table.core.windows.net` |
| `azurewebsites.net` | `privatelink.azurewebsites.net` |
| `monitor.azure.com` | `privatelink.monitor.azure.com` |
| `oms.opinsights.azure.com` | `privatelink.oms.opinsights.azure.com` |
| `ods.opinsights.azure.com` | `privatelink.ods.opinsights.azure.com` |
| `agentsvc.azure-automation.net` | `privatelink.agentsvc.azure-automation.net` |

4. Sul forwarder Azure, risolvere questi domini tramite Azure DNS senza reinoltrarli al DNS di origine. Non inoltrare direttamente da on-premises a `168.63.129.16` e non creare zone autoritative vuote per i domini pubblici.
5. Configurare il client amministrativo per usare gli stessi DNS. Mantenere la risoluzione delle zone aziendali e delle dipendenze pubbliche Azure/Entra.

Dal client privato eseguire:

```powershell
$dns = '<IPv4-DNS-primario>'
foreach ($service in 'blob', 'file', 'queue', 'table') {
    Resolve-DnsName "$storage.$service.core.windows.net" -Server $dns -ErrorAction Stop
    if (-not (Test-NetConnection "$storage.$service.core.windows.net" -Port 443 -InformationLevel Quiet)) {
        throw "Storage $service non raggiungibile su HTTPS"
    }
}
if (-not (Test-NetConnection "$storage.file.core.windows.net" -Port 445 -InformationLevel Quiet)) {
    throw 'Azure Files non raggiungibile su SMB'
}
```

Confrontare gli A record con gli IP delle NIC dei rispettivi Private Endpoint. Ripetere la risoluzione con il DNS secondario, se configurato, e con il resolver predefinito del client. Verificare anche risoluzione e accesso HTTPS ai due health endpoint. Non procedere fino alla riuscita dei controlli.

## 6. Distribuire la Logic App

Validare [application.json](infra/application.json) ed esaminare il what-if senza registrare o condividere valori sensibili:

```powershell
az deployment group validate --resource-group $rg --template-file .\infra\application.json --parameters '@infra\application.parameters.local.json' --output none
if ($LASTEXITCODE -ne 0) { throw 'Validazione della Logic App non riuscita' }
az deployment group what-if --resource-group $rg --template-file .\infra\application.json --parameters '@infra\application.parameters.local.json'
if ($LASTEXITCODE -ne 0) { throw 'What-if della Logic App non riuscito' }
```

Dopo l'approvazione delle modifiche:

```powershell
az deployment group create --resource-group $rg --name ws1-application --template-file .\infra\application.json --parameters '@infra\application.parameters.local.json' --output none
if ($LASTEXITCODE -ne 0) { throw 'Deployment della Logic App non riuscito' }
$outputsJson = az deployment group show --resource-group $rg --name ws1-application --query properties.outputs --output json
if ($LASTEXITCODE -ne 0) { throw 'Lettura degli output non riuscita' }
$outputs = $outputsJson | ConvertFrom-Json -ErrorAction Stop
$app = $outputs.appName.value
```

Verificare piano Windows WS1, VNet integration, routing della content share, DNS primario/secondario, app public network access `Disabled`, Basic Auth SCM/FTP disabilitata e Private Endpoint app `Approved`.

Non modificare le connection string generate dal template e non stampare l'insieme degli app settings. Verificare l'accesso effettivo alla share al passaggio 8: `WEBSITE_SKIP_CONTENTSHARE_VALIDATION` non certifica il montaggio SMB del worker.

## 7. Pubblicare il workflow

1. Dal Private Endpoint app, annotare l'IPv4 della NIC.
2. Leggere gli hostname app e SCM:

```powershell
az webapp show --resource-group $rg --name $app --query "{app:defaultHostName,hostnames:enabledHostNames}" --output json
if ($LASTEXITCODE -ne 0) { throw 'Lettura degli hostname non riuscita' }
Resolve-DnsName '<hostname-app>' -Server $dns -ErrorAction Stop
Resolve-DnsName '<hostname-con-.scm.>' -Server $dns -ErrorAction Stop
```

3. Verificare che entrambi risolvano alla NIC del Private Endpoint app.
4. Assegnare all'operatore Website Contributor sulla sola Logic App oppure un ruolo custom equivalente. Dal client privato autenticato con Azure CLI, eseguire [Publish-Availability.ps1](scripts/Publish-Availability.ps1):

```powershell
.\scripts\Publish-Availability.ps1 -ResourceGroup $rg -AppName $app -ExpectedAppPrivateIp '<IPv4-Private-Endpoint-app>'
```

Attendere `PASS: private Entra ZIP deployment completed`. Se il tempo di attesa scade, ispezionare il deployment SCM esistente prima di riprovare. Non abilitare Basic Auth o accesso pubblico a SCM.

## 8. Verificare DNS del worker e funzionamento

1. Dal client privato, aprire la console Debug di SCM. Eseguire `nameresolver.exe` per gli hostname Blob, File, Queue, Table e per i target; confrontare gli IP con quelli attesi.
2. Eseguire `tcpping.exe` su storage HTTPS 443 e File SMB 445. Non visualizzare variabili d'ambiente o connection string.
3. Acquisire sul DNS richieste correlate a un riavvio o a una nuova esecuzione, provenienti dalla subnet integration, tenendo conto della cache e di eventuale NAT. Disabilitare il logging temporaneo dopo la verifica.
4. Aprire il workflow `availability` e attendere due ricorrenze automatiche, senza usare Run Trigger. Verificare HTTP 200 per A e B e registrare ID e orari UTC.
5. Su un endpoint di test controllato, restituire temporaneamente HTTP 503 per B. Verificare che B fallisca e A continui nella stessa run. Ripristinare B e verificare una nuova run con entrambi HTTP 200.
6. Riavviare la Logic App. Verificare che workflow e cronologia persistano e che una nuova ricorrenza automatica riesca.

Ripristinare sempre le modifiche di test. In caso di errore DNS, timeout o accesso SMB fallito, correggere la causa mantenendo lo storage privato.

## 9. Verificare il rifiuto dell'accesso pubblico allo storage

1. Assegnare temporaneamente Storage Blob Data Reader sullo storage a un'identita' Entra di collaudo e attendere la propagazione.
2. Dal client privato, autenticare questa identita' ed eseguire:

```powershell
az storage container list --account-name $storage --auth-mode login --query 'length(@)' --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Lettura privata autenticata non riuscita' }
```

3. Da un client esterno senza VPN, tunnel o route privata, autenticare la stessa identita', selezionare la stessa subscription e impostare `$storage` con lo stesso nome.
4. Verificare che il DNS esterno risolva agli indirizzi pubblici e ripetere il comando `az storage container list` precedente.
5. Verificare il rifiuto HTTP 403 per restrizione di rete (`AuthorizationFailure`), a fronte della lettura privata riuscita con lo stesso ruolo e utente. Non considerare una richiesta anonima, un errore DNS, un timeout o un ruolo mancante come prova del blocco.
6. Per File, Queue e Table conservare anche flag di rete, connessioni Private Endpoint, risoluzione DNS e prove del worker. Rimuovere il ruolo di collaudo se temporaneo.

## 10. Verificare il monitoraggio e completare il deployment

Dal client privato, aprire Log Analytics con un'identita' autorizzata alla lettura ed eseguire:

```kusto
AzureDiagnostics
| where TimeGenerated > ago(30m)
| where Category == "WorkflowRuntime"
| project TimeGenerated, Resource, OperationName
| order by TimeGenerated desc
```

Filtrare sulla Logic App distribuita e correlare gli eventi con le run verificate. Controllare anche l'arrivo della telemetria nativa in Application Insights; non usare `availabilityResults` come requisito per questi controlli HTTP nativi.

Prima di utilizzare il deployment:

1. Registrare esito e ora UTC delle verifiche di rete, DNS, ricorrenza, recupero, persistenza e rifiuto pubblico autenticato. Completare le verifiche mancanti e correggere gli errori.
2. Configurare e provare alert per fallimento e assenza di nuove ricorrenze, con soglia coerente con l'intervallo di cinque minuti e la latenza di ingestion misurata.
3. Limitare tramite RBAC/PIM accesso alle chiavi, lettura/scrittura della configurazione e pubblicazione. Pianificare la rotazione della chiave aggiornando entrambe le connection string prima della revoca, quindi riavviare e ripetere le verifiche.
4. Per modificare gli URL, aggiornare solo `AVAILABILITY_SERVICE_A_URL` e `AVAILABILITY_SERVICE_B_URL` nel portale. Non riapplicare l'intero template per questa modifica.
5. Per modificare frequenza o azioni, aggiornare [workflow.json](logicapp/availability/workflow.json), ripubblicare e verificare le nuove ricorrenze.
