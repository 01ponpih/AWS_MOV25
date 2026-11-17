# AWS Uppgift 5 (v46) - IaC med CloudFormation

**Namn:** Pontus Pihlström
**Kurs:** AWS, MOV25
**Datum:** 2026-11-16
**GitHub-repo:** https://github.com/01ponpih/AWS_MOV25

## Sammanfattning
Infrastrukturen från tidigare veckor har flyttats till Infrastructure as Code (IaC) med CloudFormation. I stället för att bygga resurs för resurs med AWS CLI skapas hela miljön nu från tre YAML-mallar: nätverk, data och webb. Allt (VPC, subnät, säkerhetsgrupper, NACL, RDS, EFS, EC2, IAM och hemligheter) provisioneras som kod, och WordPress installeras automatiskt av UserData, utan manuella steg i konsolen eller webbläsaren. Miljön kan återskapas från repot med ett deploy-kommando och rivas med ett rivningskommando,förutsättningarna anges nedan.

## Arkitektur och motivering
Miljön är uppdelad i tre stackar med olika livscykler:

1. **`novatrix-natverk`**: VPC, subnät (ett publikt och två privata i olika AZ), routing, NACL:er (publik och privat) och säkerhetsgrupper. Ändras sällan.
2. **`novatrix-data`**: RDS MariaDB med lösenord i Secrets Manager, samt krypterat EFS med mount targets i de privata subnäten. Känsliga resurser som man inte vill röra av misstag.
3. **`novatrix-webb`**: Webbservern (EC2), IAM-roll och instance profile, samt WordPress-installationen via UserData. Byts oftast.

```text
novatrix-natverk ──► novatrix-data ──► novatrix-webb
       │                                     ▲
       └─────────────────────────────────────┘
(varje pil = Export i stacken till vänster, Fn::ImportValue i stacken till höger)
```

Stackarna kopplas ihop med `Export` och `Fn::ImportValue`. Uppdelningen gör att man till exempel kan byta ut webbservern utan att röra databasen. Stackarna rivs i omvänd ordning (webb, data, nätverk), eftersom en export inte kan tas bort så länge någon importerar den.

**Designval:**
1. **S3-buckets ligger utanför stackarna** (`novatrix-data-<konto>` och `novatrix-backup-<konto>`). CloudFormation kan inte radera en bucket som innehåller objekt, så en stack med backuper hade felat vid rivning. `deploy-all.sh` skapar buckets om de saknas, och `teardown-v46.sh` tömmer och tar bort dem så att hela cykeln blir ren. Det är ett medvetet labbval (i drift skulle backuper bevaras).
2. **`DeletionPolicy: Delete` på databasen** är ett labbval så att rivningen blir fullständig. I drift hade jag valt `Snapshot` för att behålla en sista backup.
3. **Hemligheter hanteras av Secrets Manager.** Databasens och WordPress-adminens lösenord genereras av CloudFormation och finns aldrig i mallarna, i Git eller i UserData.

## Parametrisering
Det som varierar mellan miljöer är parametrar, så att en kopia av stacken kan byggas genom att ändra till exempel prefixet.

**Parametrar:** `Prefix`, `MyIp`, `KeyName`, `DataBucket`, `BackupBucket`, `DbInstanceClass` samt nätverkets CIDR-block (med standardvärden). Därutöver finns bland annat `DbEngineVersion`, `BackupRetentionDays`, `InstanceType` och WordPress-inställningar, alla med standardvärden. Portar är hårdkodade eftersom de är en del av designen.

## Delmoment 1 & 2: Repo och templates
Avsnittet för v46 är den här filen (`V46/README.md`) och mappen `V46/`, som är versionshanterad i kursrepot:

```text
V46/
├── natverk.yaml        # stack 1: nätverk och säkerhetsgrupper
├── data.yaml           # stack 2: RDS och EFS
├── webb.yaml           # stack 3: EC2, IAM och WordPress
├── deploy-all.sh       # skapar buckets, validerar och deployar de tre stackarna
├── verify.sh           # samlar bevis att allt fungerar
├── teardown-v46.sh     # river stackarna och rensar buckets
└── README.md           # den här dokumentationen
```

All kod finns bifogad i slutet av dokumentet.

---

## Delmoment 3 & 5: Deploy och återskapande
Hela miljön byggs med ett kommando. `deploy-all.sh` gör följande i ordning:

1. Kontrollerar IP-adress och att key pair finns i regionen.
2. Skapar de två S3-buckets om de saknas (publik åtkomst blockerad, 14-dagars livscykelregel på `backup/` i backup-bucketen).
3. Validerar de tre mallarna med `aws cloudformation validate-template`.
4. Deployar `novatrix-natverk`, sedan `novatrix-data` (RDS tar ca 5-10 min) och sist `novatrix-webb`, som väntar på att WordPress-installationen signalerar klart (`cfn-signal`).
5. Skriver ut webbadress och kommandot för att hämta adminlösenordet.

**Förutsättningar:**
- AWS CLI v2, konfigurerat för regionen `eu-north-1`, med behörighet att skapa CloudFormation-, EC2-, RDS-, EFS-, IAM-, Secrets Manager- och S3-resurser.
- Ett key pair som heter `novatrix-key` i regionen.
- Git samt bash och `curl` (Git Bash fungerar på Windows).
- `MY_IP` måste anges manuellt om man kör från CloudShell eller från en annan plats än den dator man ska ansluta med via SSH.

```bash
# Klona repot och gå till mappen
git clone https://github.com/01ponpih/AWS_MOV25.git && cd AWS_MOV25/V46

# Kör deployen (byt <din-IP> mot din publika IP; utelämnas MY_IP hämtas den automatiskt)
MY_IP=<din-IP>/32 KEY_NAME=novatrix-key bash deploy-all.sh
```

Hela deployen tar ungefär 15-20 minuter. Lösenorden hanteras automatiskt: CloudFormation skapar slumpmässiga lösenord i AWS Secrets Manager, och UserData-skriptet på webbservern hämtar dem därifrån med `aws secretsmanager get-secret-value` och skapar `wp-config.php` samt installerar WordPress med `wp-cli`. Inga steg i webbläsaren behövs. Adminlösenordet hämtas med kommandot som skrivs ut i slutet av deployen:

```bash
aws secretsmanager get-secret-value --secret-id <WpAdminSecretArn> --query SecretString --output text
```

Användarnamnet är `novatrix_admin`.

**Vid felsökning:** Om UserData skulle misslyckas rullas webb-stacken tillbaka och instansen försvinner. Med `DISABLE_ROLLBACK=1 bash deploy-all.sh` rullas den inte tillbaka, så man kan logga in på instansen och läsa `/var/log/cloud-init-output.log`. En misslyckad stack måste då tas bort manuellt innan nästa försök.

**Bevis på deploy:**
De tre stackarna skapade och WordPress installerat.

![CloudFormation Stackar](<Skärmbild 2026-11-16 144154.png>)

![WordPress Dashboard](<Skärmbild 2026-11-16 144439.png>)

**Rivning:**

> **Varning:** `teardown-v46.sh` är destruktivt och frågar inte efter bekräftelse. Det raderar databasen permanent (ingen slutsnapshot) och EFS, och tömmer och tar bort båda S3-buckets, inklusive alla databasbackuper och data-bucketen som även användes i tidigare uppgifter. Kör det bara när miljön inte längre behövs.

```bash
bash teardown-v46.sh
```
Skriptet gör i ordning: 1) raderar stackarna i omvänd ordning (`novatrix-webb`, `novatrix-data`, `novatrix-natverk`) och väntar på att varje stack är borta, 2) tömmer de två S3-buckets (data-bucketen och backup-bucketen), 3) tar bort bucketarna. Därefter är allt som `deploy-all.sh` skapat borta.

---

## Delmoment 4: Versionshantering
**Ändring:** I `data.yaml` lade jag till taggen `Course: MOV25` på databasen (resursen `DbInstance`). Jag valde en tagg eftersom en ändring av bara taggar inte kräver omstart eller ersättning av databasen, vilket gör den ofarlig att demonstrera på en körande miljö.

Taggen hamnade först av misstag på Secrets Manager-hemligheten i stället för på databasen (commit `f009897`). Jag upptäckte det och flyttade taggen till `DbInstance` och gjorde en ny commit (`4dbbc72`). Historiken för mappen visar förloppet inklusive den senare justeringen av `deploy-all.sh`:

```text
$ git log --oneline 3f17ad5^..59137d8 -- V46/
59137d8 chore(v46): remove CloudShell IP check from deploy-all.sh, document DISABLE_ROLLBACK
4dbbc72 fix(v46): move Course tag to DbInstance
f009897 chore(v46): add Course tag to database for version control demo
3f17ad5 feat(v46): working CloudFormation stack (VG) - network, data and web
```

Rättningen i `4dbbc72` (utdrag ur `git show 4dbbc72 -- V46/data.yaml`):

```diff
@@ -43,8 +43,6 @@ Resources:
       Tags:
         - Key: Name
           Value: !Sub '${Prefix}-db-secret'
-        - Key: Course
-          Value: MOV25
 
   DbSubnetGroup:
     Type: AWS::RDS::DBSubnetGroup
@@ -81,6 +79,8 @@ Resources:
       Tags:
         - Key: Name
           Value: !Sub '${Prefix}-db'
+        - Key: Course
+          Value: MOV25
 
   DbSecretAttachment:
     Type: AWS::SecretsManager::SecretTargetAttachment
```

Hela ändringarna kan visas med `git show f009897 -- V46/data.yaml` och `git show 4dbbc72 -- V46/data.yaml`, eller på GitHub under respektive commit.

Efter ändringen kördes deployen igen. Utskriften från `verify.sh` längre ned visar att bara `novatrix-data` fick status `UPDATE_COMPLETE`, medan `novatrix-natverk` och `novatrix-webb` var oförändrade (`CREATE_COMPLETE`), och att databasen efteråt var `available`.

**Justering efter demonstrationen:** Efter demonstrationen gjorde jag en liten justering i `deploy-all.sh`: jag tog bort en kontroll som försökte gissa att IP-adressen tillhörde CloudShell (den gissade fel på IP-serier) och lade till en kommentar om `DISABLE_ROLLBACK`. Ändringen finns i commit `59137d8` och påverkar inte mallarna. Bilagan nedan visar den aktuella versionen.

**Hur versionshantering hjälper drift:** Varje ändring i infrastrukturen får en commit med författare, tid och motivering. Mitt eget misstag ovan (taggen på fel resurs) syns i historiken och rättades i en egen liten commit som är lätt att granska och förstå. Man kan se exakt vad som ändrades och när ett fel uppstod. Misslyckas en ändring kan man backa med `git revert` och göra en ny deploy. Med change sets (`--no-execute-changeset`) kan man förhandsgranska effekten innan den genomförs, och hela miljön kan återskapas från en känd version.

**Hur det hjälper samarbete:** Flera personer kan arbeta i olika grenar och föreslå ändringar via pull requests, där någon annan granskar diffen innan den driftsätts. Repot blir den gemensamma sanningen, så att ändringar inte görs manuellt i konsolen utan att någon vet om det, och en ny medarbetare kan bygga samma miljö med de kommandon som står i dokumentationen.

---

## VG-krav uppfyllda (inga manuella steg)
Här är en översikt över var de olika delarna av VG-kravet finns i koden:

| Del | Var i koden |
|-----|-------------|
| Nätverk | `natverk.yaml`: VPC, subnät, IGW, routing, NACL (publik + privat) |
| Säkerhet | Security groups, privat NACL, IAM-roll med minsta rättigheter, Secrets Manager, krypterad RDS/EFS/disk, EFS-policy (TLS), IMDSv2 |
| Databas och lagring | `data.yaml`: RDS MariaDB (privat) och EFS med mount targets |
| Compute | `webb.yaml`: EC2, instance profile, UserData som installerar WordPress |
| Hemligheter | `AWS::SecretsManager::Secret` + `{{resolve:secretsmanager:…}}` i RDS, `get-secret-value` i UserData |
| Koppling mellan stackar | `Export` / `Fn::ImportValue` (visas i `list-exports`) |
| Ordning och synkronisering | `DependsOn: GatewayAttachment` på `PublicRoute`, `CreationPolicy` med `cfn-signal` |
| Parametrar | `Prefix`, `MyIp`, `KeyName`, `DataBucket`, `BackupBucket`, `DbInstanceClass` m.fl. |
| Inga manuella steg | `wp core install` i UserData, `deploy-all.sh`, `teardown-v46.sh` |

**EFS-policy (TLS):** EFS-filsystemets policy är definierad i `data.yaml` (egenskapen `FileSystemPolicy`) och nekar all trafik som inte använder TLS (`aws:SecureTransport: false`). Webbservern monterar med `mount -t efs -o tls`, och UserData fortsätter bara om `mountpoint -q` bekräftar monteringen. Att `novatrix-webb` blev `CREATE_COMPLETE` (som kräver `cfn-signal` i slutet av skriptet) visar därför att monteringen fungerade med policyn på plats.

---

## Verifiering
Här är utskriften från `verify.sh`, som kontrollerar att alla stackar är skapade och att resurserna fungerar som de ska.

```text
$ bash verify.sh
==========================================
 V46 Verification
==========================================

== 1. CloudFormation Stackar
-----------------------------------------
|              ListStacks               |
+-------------------+-------------------+
|  novatrix-webb    |  CREATE_COMPLETE  |
|  novatrix-data    |  UPDATE_COMPLETE  |
|  novatrix-natverk |  CREATE_COMPLETE  |
+-------------------+-------------------+

== 2. Exports (bevis på att stackarna kopplats ihop)
-----------------------------------------------------------------------------------------------------------------------------
|                                                        ListExports                                                        |
+------------------------------------+--------------------------------------------------------------------------------------+
|  novatrix-data-DbEndpoint          |  novatrix-data-dbinstance-0mj6e9d6gjjx.cjwqgcgoc96y.eu-north-1.rds.amazonaws.com     |
|  novatrix-data-DbName              |  wordpress                                                                           |
|  novatrix-data-DbSecretArn         |  arn:aws:secretsmanager:eu-north-1:373117960549:secret:DbSecret-Ckk2fSWVHsuM-2cZzB2  |
|  novatrix-data-EfsId               |  fs-0bdc5319a9c6e8072                                                                |
|  novatrix-natverk-DbSgId           |  sg-07fba1abe4a9b9de4                                                                |
|  novatrix-natverk-EfsSgId          |  sg-095c8047d934c9f2c                                                                |
|  novatrix-natverk-PrivateSubnetAId |  subnet-0a77aa8ad0811b21c                                                            |
|  novatrix-natverk-PrivateSubnetBId |  subnet-00d37e88af81edb98                                                            |
|  novatrix-natverk-PublicSubnetId   |  subnet-0ba2ede2bb88cef15                                                            |
|  novatrix-natverk-VpcId            |  vpc-02fde82a33bc22a41                                                               |
|  novatrix-natverk-WebSgId          |  sg-069665b40926cdacb                                                                |
+------------------------------------+--------------------------------------------------------------------------------------+

== 3. RDS-instans (dynamisk sökning eftersom CF genererar namnet)
---------------------------------------------------------------------------------------------------
|                                       DescribeDBInstances                                       |
+------------+------------------------------------------------------------------------------------+
|  BackupDays|  1                                                                                 |
|  Encrypted |  True                                                                              |
|  Endpoint  |  novatrix-data-dbinstance-0mj6e9d6gjjx.cjwqgcgoc96y.eu-north-1.rds.amazonaws.com   |
|  Engine    |  mariadb                                                                           |
|  Identifier|  novatrix-data-dbinstance-0mj6e9d6gjjx                                             |
|  MultiAZ   |  False                                                                             |
|  Public    |  False                                                                             |
|  Status    |  available                                                                         |
|  Version   |  11.8.9                                                                            |
+------------+------------------------------------------------------------------------------------+

== 4. EFS (mount targets i båda subnäten)
------------------------------
|    DescribeMountTargets    |
+--------------+-------------+
|  eu-north-1a |  available  |
|  eu-north-1b |  available  |
+--------------+-------------+

== 5. S3 Backup-bucket (lifecycle 14 dagar)
----------------------------------------------------------------------
|                   GetBucketLifecycleConfiguration                  |
+-------------------+--------------------------+----------+----------+
| ExpiresAfterDays  |           ID             | Prefix   | Status   |
+-------------------+--------------------------+----------+----------+
|  14               |  expire-backups-14-days  |  backup/ |  Enabled |
+-------------------+--------------------------+----------+----------+

== 6. WordPress – HTTP-svar
   Webbplats: http://ec2-13-48-13-206.eu-north-1.compute.amazonaws.com/
   OK: WordPress svarar med HTTP 200

== 7. WordPress Admin-lösenord finns i Secrets Manager
   OK: Secret finns
   Läs lösenordet med:
   aws secretsmanager get-secret-value --secret-id arn:aws:secretsmanager:eu-north-1:373117960549:secret:WpAdminSecret-WB5xFbs5b193-JhKZte --query SecretString --output text

== 8. S3 Backup – finns en backup från första körningen?
2026-11-16 14:14:00       7361 wordpress-20261116-131358.sql.gz

==========================================
 Klart! Granska ovanstående utskrifter.
==========================================
```
---

## Kända begränsningar
* Sajten körs över HTTP. I drift hade jag lagt till en domän, ett ACM-certifikat och en Application Load Balancer för HTTPS.
* Anslutningen till RDS är krypterad (`MYSQLI_CLIENT_SSL`) men servercertifikatet verifieras inte.
* `DeletionPolicy: Delete` på databasen och den fullständiga rivningen av data och backuper är labbval (se designvalen och varningen under Rivning). I drift skulle databasen ha `Snapshot` och backuper skulle bevaras.
* SSH är öppet bara för `MyIp`. Byter man nätverk går det inte att ansluta med SSH förrän stacken uppdaterats, men rollen har `AmazonSSMManagedInstanceCore`, så Session Manager kan användas.
* AMI:n hämtas som "senaste Amazon Linux 2023". En framtida uppdatering av webb-stacken kan därför byta ut instansen.

---

## Bilaga: Skript

### `natverk.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Novatrix v46 - Nätverksstack (VPC, subnät, routing, NACL, security groups).
  Exporterar ID:n som novatrix-data och novatrix-webb importerar.

Parameters:
  Prefix:
    Type: String
    Default: novatrix
    AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
    ConstraintDescription: Små bokstäver, siffror och bindestreck (2-21 tecken).
  MyIp:
    Type: String
    Description: Din publika IP i CIDR-format, t.ex. 203.0.113.10/32 (används för SSH).
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$'
    ConstraintDescription: Ange en IPv4-adress i CIDR-format, t.ex. 203.0.113.10/32.
  VpcCidr:
    Type: String
    Default: 10.0.0.0/16
  PublicSubnetCidr:
    Type: String
    Default: 10.0.1.0/24
  PrivateSubnetACidr:
    Type: String
    Default: 10.0.2.0/24
  PrivateSubnetBCidr:
    Type: String
    Default: 10.0.4.0/24

Resources:
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-vpc'

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-igw'

  GatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  PublicSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Ref PublicSubnetCidr
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-public'

  PrivateSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Ref PrivateSubnetACidr
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-private-a'

  PrivateSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Ref PrivateSubnetBCidr
      AvailabilityZone: !Select [1, !GetAZs '']
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-private-b'

  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-public-rt'

  PublicRoute:
    Type: AWS::EC2::Route
    DependsOn: GatewayAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnetRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref PublicRouteTable

  PrivateRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-private-rt'

  PrivateSubnetARouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetA
      RouteTableId: !Ref PrivateRouteTable

  PrivateSubnetBRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetB
      RouteTableId: !Ref PrivateRouteTable

  PublicNacl:
    Type: AWS::EC2::NetworkAcl
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-public-nacl'

  PublicInHttp:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PublicNacl, RuleNumber: 100, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: 0.0.0.0/0, PortRange: { From: 80, To: 80 } }
  PublicInHttps:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PublicNacl, RuleNumber: 110, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: 0.0.0.0/0, PortRange: { From: 443, To: 443 } }
  PublicInSsh:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PublicNacl, RuleNumber: 120, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: !Ref MyIp, PortRange: { From: 22, To: 22 } }
  PublicInEphemeral:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PublicNacl, RuleNumber: 130, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: 0.0.0.0/0, PortRange: { From: 1024, To: 65535 } }

  PublicOutHttp:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PublicNacl, RuleNumber: 100, Protocol: 6, RuleAction: allow, Egress: true, CidrBlock: 0.0.0.0/0, PortRange: { From: 80, To: 80 } }
  PublicOutHttps:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PublicNacl, RuleNumber: 110, Protocol: 6, RuleAction: allow, Egress: true, CidrBlock: 0.0.0.0/0, PortRange: { From: 443, To: 443 } }
  PublicOutEphemeral:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PublicNacl, RuleNumber: 120, Protocol: 6, RuleAction: allow, Egress: true, CidrBlock: 0.0.0.0/0, PortRange: { From: 1024, To: 65535 } }
  PublicOutMariaDb:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PublicNacl, RuleNumber: 140, Protocol: 6, RuleAction: allow, Egress: true, CidrBlock: !Ref VpcCidr, PortRange: { From: 3306, To: 3306 } }
  PublicOutNfs:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PublicNacl, RuleNumber: 150, Protocol: 6, RuleAction: allow, Egress: true, CidrBlock: !Ref VpcCidr, PortRange: { From: 2049, To: 2049 } }

  PublicSubnetNaclAssociation:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties: { SubnetId: !Ref PublicSubnet, NetworkAclId: !Ref PublicNacl }

  PrivateNacl:
    Type: AWS::EC2::NetworkAcl
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-private-nacl'

  PrivateInMariaDb:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PrivateNacl, RuleNumber: 100, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: !Ref PublicSubnetCidr, PortRange: { From: 3306, To: 3306 } }
  PrivateInNfs:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PrivateNacl, RuleNumber: 110, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: !Ref PublicSubnetCidr, PortRange: { From: 2049, To: 2049 } }
  PrivateOutEphemeral:
    Type: AWS::EC2::NetworkAclEntry
    Properties: { NetworkAclId: !Ref PrivateNacl, RuleNumber: 100, Protocol: 6, RuleAction: allow, Egress: true, CidrBlock: !Ref PublicSubnetCidr, PortRange: { From: 1024, To: 65535 } }

  PrivateSubnetANaclAssociation:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties: { SubnetId: !Ref PrivateSubnetA, NetworkAclId: !Ref PrivateNacl }
  PrivateSubnetBNaclAssociation:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties: { SubnetId: !Ref PrivateSubnetB, NetworkAclId: !Ref PrivateNacl }

  WebSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Web server - HTTP/HTTPS from internet, SSH from MyIp
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 80,  ToPort: 80,  CidrIp: 0.0.0.0/0 }
        - { IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: 0.0.0.0/0 }
        - { IpProtocol: tcp, FromPort: 22,  ToPort: 22,  CidrIp: !Ref MyIp }
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-web-sg'

  DbSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Database - MariaDB 3306 only from web-sg
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 3306, ToPort: 3306, SourceSecurityGroupId: !Ref WebSg }
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-db-sg'

  EfsSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: EFS - NFS 2049 only from web-sg
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 2049, ToPort: 2049, SourceSecurityGroupId: !Ref WebSg }
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-efs-sg'

Outputs:
  VpcId:
    Value: !Ref Vpc
    Export: { Name: !Sub '${Prefix}-natverk-VpcId' }
  PublicSubnetId:
    Value: !Ref PublicSubnet
    Export: { Name: !Sub '${Prefix}-natverk-PublicSubnetId' }
  PrivateSubnetAId:
    Value: !Ref PrivateSubnetA
    Export: { Name: !Sub '${Prefix}-natverk-PrivateSubnetAId' }
  PrivateSubnetBId:
    Value: !Ref PrivateSubnetB
    Export: { Name: !Sub '${Prefix}-natverk-PrivateSubnetBId' }
  WebSgId:
    Value: !Ref WebSg
    Export: { Name: !Sub '${Prefix}-natverk-WebSgId' }
  DbSgId:
    Value: !Ref DbSg
    Export: { Name: !Sub '${Prefix}-natverk-DbSgId' }
  EfsSgId:
    Value: !Ref EfsSg
    Export: { Name: !Sub '${Prefix}-natverk-EfsSgId' }
```

### `data.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Novatrix v46 - Datastack (RDS MariaDB med lösenord i Secrets Manager, krypterat EFS med mount targets).

Parameters:
  Prefix:
    Type: String
    Default: novatrix
    AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
  DbInstanceClass:
    Type: String
    Default: db.t3.micro
    AllowedValues: [db.t3.micro, db.t3.small, db.t3.medium, db.t4g.micro, db.t4g.small]
  DbEngineVersion:
    Type: String
    Default: "11.8"
    Description: Huvudversion av MariaDB. RDS väljer en aktuell patchversion.
  DbName:
    Type: String
    Default: wordpress
    AllowedPattern: '^[a-zA-Z][a-zA-Z0-9]{0,62}$'
  DbUsername:
    Type: String
    Default: dbadmin
    AllowedPattern: '^[a-zA-Z][a-zA-Z0-9_]{0,15}$'
  BackupRetentionDays:
    Type: Number
    Default: 1
    MinValue: 0
    MaxValue: 35
    Description: Free plan tillåter högst 1 dag. I drift hade 7 dagar valts.

Resources:
  DbSecret:
    Type: AWS::SecretsManager::Secret
    Properties:
      Description: !Sub 'Master credentials for ${Prefix} RDS'
      GenerateSecretString:
        SecretStringTemplate: !Sub '{"username":"${DbUsername}"}'
        GenerateStringKey: password
        PasswordLength: 24
        ExcludePunctuation: true
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-db-secret'

  DbSubnetGroup:
    Type: AWS::RDS::DBSubnetGroup
    Properties:
      DBSubnetGroupDescription: Private subnets for RDS
      SubnetIds:
        - Fn::ImportValue: !Sub '${Prefix}-natverk-PrivateSubnetAId'
        - Fn::ImportValue: !Sub '${Prefix}-natverk-PrivateSubnetBId'
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-db-subnets'

  DbInstance:
    Type: AWS::RDS::DBInstance
    DeletionPolicy: Delete
    UpdateReplacePolicy: Delete
    Properties:
      Engine: mariadb
      EngineVersion: !Ref DbEngineVersion
      DBInstanceClass: !Ref DbInstanceClass
      AllocatedStorage: '20'
      StorageType: gp2
      StorageEncrypted: true
      DBName: !Ref DbName
      MasterUsername: !Sub '{{resolve:secretsmanager:${DbSecret}:SecretString:username}}'
      MasterUserPassword: !Sub '{{resolve:secretsmanager:${DbSecret}:SecretString:password}}'
      DBSubnetGroupName: !Ref DbSubnetGroup
      VPCSecurityGroups:
        - Fn::ImportValue: !Sub '${Prefix}-natverk-DbSgId'
      PubliclyAccessible: false
      MultiAZ: false
      BackupRetentionPeriod: !Ref BackupRetentionDays
      CopyTagsToSnapshot: true
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-db'
        - Key: Course
          Value: MOV25

  DbSecretAttachment:
    Type: AWS::SecretsManager::SecretTargetAttachment
    Properties:
      SecretId: !Ref DbSecret
      TargetId: !Ref DbInstance
      TargetType: AWS::RDS::DBInstance

  FileSystem:
    Type: AWS::EFS::FileSystem
    Properties:
      Encrypted: true
      PerformanceMode: generalPurpose
      ThroughputMode: bursting
      LifecyclePolicies:
        - TransitionToIA: AFTER_30_DAYS
      FileSystemTags:
        - Key: Name
          Value: !Sub '${Prefix}-efs'
      FileSystemPolicy:
        Version: "2012-10-17"
        Statement:
          - Sid: AllowMount
            Effect: Allow
            Principal: { AWS: "*" }
            Action:
              - elasticfilesystem:ClientMount
              - elasticfilesystem:ClientWrite
              - elasticfilesystem:ClientRootAccess
            Resource: "*"
          - Sid: DenyUnencryptedTransport
            Effect: Deny
            Principal: { AWS: "*" }
            Action: "*"
            Resource: "*"
            Condition:
              Bool:
                aws:SecureTransport: "false"

  MountTargetA:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref FileSystem
      SubnetId:
        Fn::ImportValue: !Sub '${Prefix}-natverk-PrivateSubnetAId'
      SecurityGroups:
        - Fn::ImportValue: !Sub '${Prefix}-natverk-EfsSgId'

  MountTargetB:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref FileSystem
      SubnetId:
        Fn::ImportValue: !Sub '${Prefix}-natverk-PrivateSubnetBId'
      SecurityGroups:
        - Fn::ImportValue: !Sub '${Prefix}-natverk-EfsSgId'

Outputs:
  EfsId:
    Value: !Ref FileSystem
    Export: { Name: !Sub '${Prefix}-data-EfsId' }
  DbEndpoint:
    Value: !GetAtt DbInstance.Endpoint.Address
    Export: { Name: !Sub '${Prefix}-data-DbEndpoint' }
  DbName:
    Value: !Ref DbName
    Export: { Name: !Sub '${Prefix}-data-DbName' }
  DbSecretArn:
    Value: !Ref DbSecret
    Export: { Name: !Sub '${Prefix}-data-DbSecretArn' }
```

### `webb.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  Novatrix v46 - Webbstack (EC2 med WordPress, IAM-roll, Secrets Manager för WP-admin).

Parameters:
  Prefix:
    Type: String
    Default: novatrix
    AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
  KeyName:
    Type: AWS::EC2::KeyPair::KeyName
  DataBucket:
    Type: String
    AllowedPattern: '^[a-z0-9][a-z0-9.-]{2,62}$'
  BackupBucket:
    Type: String
    AllowedPattern: '^[a-z0-9][a-z0-9.-]{2,62}$'
  InstanceType:
    Type: String
    Default: t3.micro
    AllowedValues: [t3.micro, t3.small, t3.medium]
  LatestAmiId:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
  WpTitle:
    Type: String
    Default: Novatrix AB
    AllowedPattern: '^[A-Za-z0-9 ]{1,40}$'
  WpAdminUser:
    Type: String
    Default: novatrix_admin
    AllowedPattern: '^[a-z][a-z0-9_]{2,30}$'
  WpAdminEmail:
    Type: String
    Default: admin@novatrix.example

Resources:
  WpAdminSecret:
    Type: AWS::SecretsManager::Secret
    Properties:
      Description: !Sub 'WordPress admin password for ${Prefix}'
      GenerateSecretString:
        PasswordLength: 20
        ExcludePunctuation: true
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-wp-admin-secret'

  WebRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: { Service: ec2.amazonaws.com }
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore'
      Policies:
        - PolicyName: s3-data-read
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - { Effect: Allow, Action: s3:ListBucket, Resource: !Sub 'arn:${AWS::Partition}:s3:::${DataBucket}' }
              - { Effect: Allow, Action: s3:GetObject, Resource: !Sub 'arn:${AWS::Partition}:s3:::${DataBucket}/*' }
        - PolicyName: s3-backup-write
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - { Effect: Allow, Action: [s3:PutObject, s3:AbortMultipartUpload], Resource: !Sub 'arn:${AWS::Partition}:s3:::${BackupBucket}/backup/*' }
        - PolicyName: read-own-secrets
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: secretsmanager:GetSecretValue
                Resource:
                  - Fn::ImportValue: !Sub '${Prefix}-data-DbSecretArn'
                  - !Ref WpAdminSecret
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-web-role'

  WebInstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles: [!Ref WebRole]

  WebInstance:
    Type: AWS::EC2::Instance
    CreationPolicy:
      ResourceSignal:
        Count: 1
        Timeout: PT20M
    Properties:
      ImageId: !Ref LatestAmiId
      InstanceType: !Ref InstanceType
      KeyName: !Ref KeyName
      IamInstanceProfile: !Ref WebInstanceProfile
      SubnetId:
        Fn::ImportValue: !Sub '${Prefix}-natverk-PublicSubnetId'
      SecurityGroupIds:
        - Fn::ImportValue: !Sub '${Prefix}-natverk-WebSgId'
      MetadataOptions: { HttpTokens: required, HttpEndpoint: enabled }
      BlockDeviceMappings:
        - DeviceName: /dev/xvda
          Ebs: { VolumeType: gp3, VolumeSize: 8, Encrypted: true, DeleteOnTermination: true }
      Tags:
        - Key: Name
          Value: !Sub '${Prefix}-web'
      UserData:
        Fn::Base64: !Sub
          - |
            #!/bin/bash
            set -eEuo pipefail
            export AWS_DEFAULT_REGION=${AWS::Region}
            WP_DIR=/var/www/html

            dnf install -y aws-cfn-bootstrap
            signal() { /opt/aws/bin/cfn-signal -e "$1" --stack ${AWS::StackName} --resource WebInstance --region ${AWS::Region} || true; }
            trap 'rc=$?; if [ $rc -ne 0 ]; then signal 1; fi' EXIT

            dnf install -y httpd php php-fpm php-mysqlnd php-gd php-xml php-mbstring \
              php-intl php-opcache php-cli php-zip mariadb105 amazon-efs-utils jq cronie

            DB_JSON=""
            for i in 1 2 3 4 5 6; do
              DB_JSON=$(aws secretsmanager get-secret-value --secret-id ${DbSecretArn} --query SecretString --output text) && break
              sleep 10
            done
            DB_USER=$(echo "$DB_JSON" | jq -r .username)
            DB_PASSWORD=$(echo "$DB_JSON" | jq -r .password)

            if [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" = "null" ]; then
              echo "FEL: kunde inte läsa databasuppgifterna" >&2; exit 1
            fi

            WP_ADMIN_PASSWORD=$(aws secretsmanager get-secret-value --secret-id ${WpSecretArn} --query SecretString --output text)

            mkdir -p $WP_DIR/wp-content
            grep -q ${EfsId} /etc/fstab || echo "${EfsId}:/ $WP_DIR/wp-content efs _netdev,noresvport,tls 0 0" >> /etc/fstab
            for i in 1 2 3 4 5 6; do
              timeout 90 mount -t efs -o tls ${EfsId}:/ $WP_DIR/wp-content && break
              sleep 15
            done
            mountpoint -q $WP_DIR/wp-content

            for i in 1 2 3 4 5 6; do
              MYSQL_PWD="$DB_PASSWORD" mysql --ssl -h ${DbEndpoint} -u "$DB_USER" ${DbName} -e 'SELECT 1' >/dev/null 2>&1 && break
              sleep 10
            done
            MYSQL_PWD="$DB_PASSWORD" mysql --ssl -h ${DbEndpoint} -u "$DB_USER" ${DbName} -e 'SELECT 1' >/dev/null

            cd /tmp
            curl -fsSL -o wordpress.tar.gz https://wordpress.org/latest.tar.gz
            tar -xzf wordpress.tar.gz
            cp -a /tmp/wordpress/. $WP_DIR/
            rm -rf /tmp/wordpress /tmp/wordpress.tar.gz

            curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
            chmod +x /usr/local/bin/wp
            WP="/usr/local/bin/wp --allow-root --path=$WP_DIR"

            $WP config create --dbname=${DbName} --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" \
              --dbhost=${DbEndpoint} --dbcharset=utf8mb4 --skip-check
            $WP config set DISALLOW_FILE_EDIT true --raw --type=constant
            $WP config set MYSQL_CLIENT_FLAGS MYSQLI_CLIENT_SSL --raw --type=constant

            TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
            SITE_HOST=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname || true)
            [ -n "$SITE_HOST" ] || SITE_HOST=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

            $WP core install --url="http://$SITE_HOST" --title="${WpTitle}" \
              --admin_user="${WpAdminUser}" --admin_password="$WP_ADMIN_PASSWORD" \
              --admin_email="${WpAdminEmail}" --skip-email

            cat > /etc/httpd/conf.d/novatrix.conf <<'CONF'
            ServerTokens Prod
            ServerSignature Off
            <Directory /var/www/html>
                Options -Indexes +FollowSymLinks
                AllowOverride All
            </Directory>
            CONF

            chown -R apache:apache $WP_DIR
            find $WP_DIR -type d -exec chmod 755 {} +
            find $WP_DIR -type f -exec chmod 644 {} +
            chown root:apache $WP_DIR/wp-config.php
            chmod 640 $WP_DIR/wp-config.php

            cat > /usr/local/bin/novatrix-backup.sh <<'BKP'
            #!/bin/bash
            set -euo pipefail
            export AWS_DEFAULT_REGION=${AWS::Region}
            DB_JSON=$(aws secretsmanager get-secret-value --secret-id ${DbSecretArn} --query SecretString --output text)
            DB_USER=$(echo "$DB_JSON" | jq -r .username)
            DB_PASSWORD=$(echo "$DB_JSON" | jq -r .password)
            TS=$(date +%Y%m%d-%H%M%S)
            FILE=/tmp/${DbName}-$TS.sql.gz
            trap 'rm -f "$FILE"' EXIT
            MYSQL_PWD="$DB_PASSWORD" mysqldump --ssl --host=${DbEndpoint} --user="$DB_USER" \
              --single-transaction --quick --no-tablespaces ${DbName} | gzip -9 > "$FILE"
            aws s3 cp "$FILE" "s3://${BackupBucket}/backup/${DbName}-$TS.sql.gz" --only-show-errors
            BKP

            chmod 750 /usr/local/bin/novatrix-backup.sh
            echo '0 2 * * * root /usr/local/bin/novatrix-backup.sh >> /var/log/novatrix-backup.log 2>&1' > /etc/cron.d/novatrix-backup

            systemctl enable --now php-fpm httpd crond
            /usr/local/bin/novatrix-backup.sh || true

            trap - EXIT
            signal 0
          - EfsId: !ImportValue {"Fn::Sub": "${Prefix}-data-EfsId"}
            DbEndpoint: !ImportValue {"Fn::Sub": "${Prefix}-data-DbEndpoint"}
            DbName: !ImportValue {"Fn::Sub": "${Prefix}-data-DbName"}
            DbSecretArn: !ImportValue {"Fn::Sub": "${Prefix}-data-DbSecretArn"}
            WpSecretArn: !Ref WpAdminSecret

Outputs:
  WebsiteUrl:
    Value: !Sub 'http://${WebInstance.PublicDnsName}/'
  AdminUrl:
    Value: !Sub 'http://${WebInstance.PublicDnsName}/wp-admin'
  WpAdminSecretArn:
    Description: Hämta lösenordet med aws secretsmanager get-secret-value
    Value: !Ref WpAdminSecret
```

### `deploy-all.sh`
```bash
#!/bin/bash
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

PREFIX="${PREFIX:-novatrix}"
KEY_NAME="${KEY_NAME:-novatrix-key}"
DB_CLASS="${DB_CLASS:-db.t3.micro}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DATA_BUCKET="${DATA_BUCKET:-novatrix-data-$ACCOUNT_ID}"
BACKUP_BUCKET="${BACKUP_BUCKET:-novatrix-backup-$ACCOUNT_ID}"

if [ -z "${MY_IP:-}" ]; then
  MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')/32"
fi
[[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || { echo "FEL: ogiltig MY_IP: $MY_IP"; exit 1; }

echo "== Förkontroller"
aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null \
  || { echo "FEL: key pair '$KEY_NAME' saknas i $AWS_DEFAULT_REGION"; exit 1; }

ensure_bucket() {
  local b=$1
  if aws s3api head-bucket --bucket "$b" 2>/dev/null; then
    echo "   = bucket $b finns"
    return 0
  fi
  echo "   + skapar bucket $b"
  aws s3api create-bucket --bucket "$b" \
    --create-bucket-configuration "LocationConstraint=$AWS_DEFAULT_REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$b" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  if [ "$b" = "$BACKUP_BUCKET" ]; then
    aws s3api put-bucket-lifecycle-configuration --bucket "$b" --lifecycle-configuration \
      '{"Rules":[{"ID":"expire-backups-14-days","Status":"Enabled","Filter":{"Prefix":"backup/"},"Expiration":{"Days":14},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'
  fi
}
ensure_bucket "$DATA_BUCKET"
ensure_bucket "$BACKUP_BUCKET"

echo "== Validerar templates"
for t in natverk data webb; do
  aws cloudformation validate-template --template-body "file://$t.yaml" >/dev/null
  echo "   OK $t.yaml"
done

TAGS="Project=$PREFIX ManagedBy=cloudformation"

echo "== 1/3 Stack $PREFIX-natverk"
aws cloudformation deploy --stack-name "$PREFIX-natverk" \
  --template-file natverk.yaml \
  --parameter-overrides "Prefix=$PREFIX" "MyIp=$MY_IP" \
  --no-fail-on-empty-changeset --tags $TAGS

echo "== 2/3 Stack $PREFIX-data (RDS tar ca 5-10 min)"
aws cloudformation deploy --stack-name "$PREFIX-data" \
  --template-file data.yaml \
  --parameter-overrides "Prefix=$PREFIX" "DbInstanceClass=$DB_CLASS" \
  --no-fail-on-empty-changeset --tags $TAGS

echo "== 3/3 Stack $PREFIX-webb"
# Vid felsökning kan man köra DISABLE_ROLLBACK=1 bash deploy-all.sh
ROLLBACK_FLAG=()
[ "${DISABLE_ROLLBACK:-0}" = "1" ] && ROLLBACK_FLAG=(--disable-rollback)

aws cloudformation deploy --stack-name "$PREFIX-webb" \
  --template-file webb.yaml \
  --capabilities CAPABILITY_IAM \
  ${ROLLBACK_FLAG[@]+"${ROLLBACK_FLAG[@]}"} \
  --parameter-overrides "Prefix=$PREFIX" "KeyName=$KEY_NAME" \
      "DataBucket=$DATA_BUCKET" "BackupBucket=$BACKUP_BUCKET" \
  --no-fail-on-empty-changeset --tags $TAGS

out() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}
WP_SECRET_ARN=$(out "$PREFIX-webb" WpAdminSecretArn)

echo ""
echo "============================================================"
echo " KLART! Hela stacken är utrullad som kod."
echo " Webbplats: $(out "$PREFIX-webb" WebsiteUrl)"
echo " Admin:     $(out "$PREFIX-webb" AdminUrl) (användare: novatrix_admin)"
echo ""
echo " Admin-lösenord (visas inte här):"
echo "   aws secretsmanager get-secret-value --secret-id $WP_SECRET_ARN --query SecretString --output text"
echo "============================================================"
```

### `verify.sh`
```bash
#!/bin/bash
set -e
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

echo "=========================================="
echo " V46 Verification"
echo "=========================================="

echo ""
echo "== 1. CloudFormation Stackar"
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?starts_with(StackName, 'novatrix')].[StackName,StackStatus]" \
  --output table

echo ""
echo "== 2. Exports (bevis på att stackarna kopplats ihop)"
aws cloudformation list-exports \
  --query "Exports[?starts_with(Name, 'novatrix')].[Name,Value]" \
  --output table

echo ""
echo "== 3. RDS-instans (dynamisk sökning eftersom CF genererar namnet)"
aws rds describe-db-instances \
  --query "DBInstances[?starts_with(DBInstanceIdentifier, 'novatrix-data')].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Public:PubliclyAccessible,Encrypted:StorageEncrypted,BackupDays:BackupRetentionPeriod,MultiAZ:MultiAZ,Identifier:DBInstanceIdentifier,Endpoint:Endpoint.Address}" \
  --output table

echo ""
echo "== 4. EFS (mount targets i båda subnäten)"
EFS_ID=$(aws cloudformation describe-stacks --stack-name novatrix-data \
  --query "Stacks[0].Outputs[?OutputKey=='EfsId'].OutputValue" --output text)
aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query 'MountTargets[].[AvailabilityZoneName,LifeCycleState]' --output table

echo ""
echo "== 5. S3 Backup-bucket (lifecycle 14 dagar)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3api get-bucket-lifecycle-configuration --bucket "novatrix-backup-$ACCOUNT_ID" \
  --query 'Rules[0].{ID:ID,Status:Status,Prefix:Filter.Prefix,ExpiresAfterDays:Expiration.Days}' \
  --output table

echo ""
echo "== 6. WordPress – HTTP-svar"
WEB_URL=$(aws cloudformation describe-stacks --stack-name novatrix-webb \
  --query "Stacks[0].Outputs[?OutputKey=='WebsiteUrl'].OutputValue" --output text)
echo "   Webbplats: $WEB_URL"

# Fångar HTTP-koden, ignorerar Windows/Git Bash-strul
HTTP_CODE=$(curl -s -L -o /dev/null --max-time 15 -w "%{http_code}" "$WEB_URL" 2>/dev/null || true)

# Kollar om svaret börjar med 200 eller 302, oavsett om det råkat hänga på extra nollor
if [[ "$HTTP_CODE" == 200* ]] || [[ "$HTTP_CODE" == 302* ]]; then
  echo "   OK: WordPress svarar med HTTP ${HTTP_CODE:0:3}"
else
  echo "   FEL: WordPress svarar inte (HTTP: $HTTP_CODE)."
  echo "   UserData kan fortfarande arbeta. Vänta 2 minuter och kör verify.sh igen."
fi

echo ""
echo "== 7. WordPress Admin-lösenord finns i Secrets Manager"
WP_SECRET=$(aws cloudformation describe-stacks --stack-name novatrix-webb \
  --query "Stacks[0].Outputs[?OutputKey=='WpAdminSecretArn'].OutputValue" --output text)
if aws secretsmanager describe-secret --secret-id "$WP_SECRET" >/dev/null 2>&1; then
  echo "   OK: Secret finns"
  echo "   Läs lösenordet med:"
  echo "   aws secretsmanager get-secret-value --secret-id $WP_SECRET --query SecretString --output text"
else
  echo "   FEL: hemligheten saknas"
fi

echo ""
echo "== 8. S3 Backup – finns en backup från första körningen?"
aws s3 ls "s3://novatrix-backup-$ACCOUNT_ID/backup/" 2>/dev/null || echo "   (inga backuper än – körs första gången vid cron 02:00 eller manuellt)"

echo ""
echo "=========================================="
echo " Klart! Granska ovanstående utskrifter."
echo "=========================================="
```

### `teardown-v46.sh`
```bash
#!/bin/bash
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

PREFIX="${PREFIX:-novatrix}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DATA_BUCKET="${DATA_BUCKET:-novatrix-data-$ACCOUNT_ID}"
BACKUP_BUCKET="${BACKUP_BUCKET:-novatrix-backup-$ACCOUNT_ID}"

echo "== Riv stackarna i omvänd ordning"
for s in "$PREFIX-webb" "$PREFIX-data" "$PREFIX-natverk"; do
  if aws cloudformation describe-stacks --stack-name "$s" >/dev/null 2>&1; then
    echo "   Tar bort $s..."
    aws cloudformation delete-stack --stack-name "$s"
    aws cloudformation wait stack-delete-complete --stack-name "$s"
  else
    echo "   = $s finns inte"
  fi
done

echo "== Tar bort S3-buckets (utanför stackarna)"
for bucket in "$DATA_BUCKET" "$BACKUP_BUCKET"; do
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "   Tömmer och tar bort $bucket..."
    aws s3 rm "s3://$bucket" --recursive --only-show-errors
    aws s3api delete-bucket --bucket "$bucket"
  else
    echo "   = $bucket finns inte"
  fi
done
```