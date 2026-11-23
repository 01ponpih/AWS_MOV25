# AWS Uppgift 6 (v47) - Skalbarhet och tillgänglighet

**Namn:** Pontus Pihlström
**Kurs:** AWS, MOV25
**Datum:** 2026-11-23
**GitHub-repo:** https://github.com/01ponpih/AWS_MOV25

## Sammanfattning
Infrastrukturen från v46 har byggts ut för att klara hög last och driftstörningar. Lösningen är nu uppdelad i fyra stackar där den nya stacken (`novatrix-skala`) ansvarar för en Application Load Balancer (ALB) och en Auto Scaling-grupp (ASG) som sprider trafiken över två Availability Zones. Servrarna installerar WordPress helt automatiskt via UserData och använder ett gemensamt lås på EFS för att undvika krockar vid samtidig uppstart. Hela miljön kan fortfarande deployas och rivas helt utan manuella steg.

## Arkitektur och motivering

Stackarna bygger vidare på varandra med `Export` och `Fn::ImportValue`:
1. **`novatrix-natverk`**: Uppdaterad med ett andra publikt subnät (`PublicSubnetB`) i zon B, samt en egen säkerhetsgrupp för lastbalanseraren (`AlbSg`). Webbservrarnas säkerhetsgrupp (`WebSg`) släpper nu bara in port 80 från `AlbSg`.
2. **`novatrix-data`**: Oförändrad (RDS och EFS).
3. **`novatrix-webb`**: EC2-instansen är borttagen. Kvar finns IAM-rollen, Instance Profile och hemligheter. En ny hemlighet (`WpSaltSecret`) har lagts till.
4. **`novatrix-skala`**: Hanterar ALB, Target Group, Launch Template och Auto Scaling-gruppen.

**Tre svåra problem och hur de löstes:**
Att köra WordPress på flera servrar samtidigt bakom en lastbalanserare innebär tre specifika utmaningar:
*   **Krockande installationer:** Två servrar som startar samtidigt skulle båda försöka installera WordPress och skriva över varandra på EFS. Detta löses med `flock` på en låsfil i EFS. Den första servern som startar låser filen, installerar allt, och sparar WordPress-versionen i en fil. Nästa server väntar på låset och hoppar sedan över installationen eftersom den ser att det redan är gjort.
*   **Inloggning över flera servrar:** WordPress använder "salts" för att signera inloggningscookies. Om servrarna har olika salts blir användaren utloggad varje gång lastbalanseraren skickar dem till en annan server. Detta löses genom att hämta ett slumpfrö från Secrets Manager och sedan räkna ut identiska salts på alla servrar.
*   **Felaktiga URL:er:** WordPress måste veta att den ligger bakom en lastbalanserare. Detta löses genom att sätta `WP_HOME` och `WP_SITEURL` till ALB:ns DNS-namn via UserData.

## Lastbalansering och Auto Scaling

*   **Application Load Balancer:** Ligger i två publika subnät (multi-AZ) och tar emot trafik på port 80.
*   **Health Checks:** ALB:n kontrollerar `/wp-login.php` var 15:e sekund. Detta verifierar hela kedjan (Apache -> PHP -> Databas), inte bara att servern lever. Kräver 2 lyckade kontroller för att bli healthy.
*   **Auto Scaling (Target Tracking):** Gruppen strävar efter att hålla genomsnittlig CPU på 50%. MinSize är 2 (alltid en server per zon) och MaxSize är 4.
*   **Grace period och Warmup:** Eftersom UserData tar 5–10 minuter att installera WordPress är både `HealthCheckGracePeriod` och `InstanceWarmup` satta till 600 sekunder. Detta hindrar ASG från att riva en server mitt under installationen, och hindrar skalningsalgoritmen från att feltolka den höga CPU:n under installationen som "riktig" last.

## Verifiering av skalning och failover
*(Bildbevis: Klistra in dina skärmdumpar från EC2-instanslistan och Auto Scaling Activity History här i PDF:en)*

**1. Bevis på multi-AZ (verify.sh):**

    == 4. Instanser och zoner (bevis på multi-AZ)
    |  i-07b150178bde84c2c |  eu-north-1a |  InService |  Healthy  |
    |  i-0dda8a757afc9c08a |  eu-north-1b |  InService |  Healthy  |

**2. Bevis på utskalning (lasttest.sh):**
Vid konstant last (curl-anrop) klättrade CPU:n över målet och Auto Scaling startade nya instanser.

    [14:50:52] CPU(medel)=1%   desired=2  inService=2  healthy=2
    [14:52:28] CPU(medel)=76%  desired=2  inService=2  healthy=2  <-- Lasten ökar
    [14:53:32] CPU(medel)=76%  desired=3  inService=3  healthy=2  <-- Skalar ut
    [14:55:08] CPU(medel)=75%  desired=3  inService=3  healthy=3  <-- Ny server redo
    [15:04:13] CPU(medel)=57%  desired=4  inService=3  healthy=3  <-- Når MaxSize

**3. Bevis på hög tillgänglighet (failover-test.sh):**
En server tvångsavslutades i `eu-north-1a` medan 88 curl-anrop skickades mot sajten.

    [15:56:17] Avslutar server i-09acb83ab5c9c0b59 (zon eu-north-1a).
    [15:56:18] healthy=1/2  (förfluten tid: 1 s)
    ...
    [15:57:52] healthy=2/2  (förfluten tid: 95 s)
    [15:58:02] Återhämtad: 2 servrar är healthy igen efter 105 s, utan manuell handpåläggning.
    [15:58:02] Anrop som inte gav 200: 0 av 88

Tack vare `deregistration_delay` (30s) hanterade ALB:n avregistreringen snyggt. Sajten svarade 200 på alla anrop under hela händelseförloppet, och Auto Scaling startade en ersättare helt automatiskt.

## Kostnadsberäkning (AWS Pricing Calculator)

**Antaganden:** Region `eu-north-1` (Stockholm), priser i USD/månad (ca 10,5 SEK/USD).
*   **Normal last (2 instanser, 24/7):**
    *   ALB (fast timkostnad + LCU): ~$22
    *   2 × t3.micro EC2 (inkl. detaljerad övervakning): ~$18
    *   RDS db.t3.micro (Single-AZ): ~$15
    *   EFS, S3, Secrets Manager: ~$5
    *   *Totalt: ca $60/månad (ca 630 kr).*
*   **Vid utskalning (4 instanser under några timmar/dag):**
    *   EC2-kostnaden ökar med ca $18/månad om gruppen ligger på max 4 instanser en längre tid.
    *   *Totalt vid konstant maxlast: ca $78/månad.*

**Vad kostar mest?** Lastbalanseraren (ALB) och databasen (RDS) är de fasta kostnaderna som löper dygnet runt oavsett last. EC2-instanserna är billiga i grunden men ökar linjärt när gruppen skalar ut.

## Kända begränsningar
*   Sajten körs över HTTP. I drift hade ALB:en fått en HTTPS-lyssnare med ett ACM-certifikat.
*   Databasen (RDS) är Single-AZ. För full redundans hade Multi-AZ valts, men det dubblar databaskostnaden.
*   `DeletionPolicy: Delete` på databasen är ett labbval för att rivningen ska bli fullständig.
*   `lasttest.sh` och `failover-test.sh` använder `date -d` och är testade i Git Bash/CloudShell, men fungerar inte rakt av på macOS (BSD date).

---

## Bilaga: Skript

### natverk.yaml

    AWSTemplateFormatVersion: '2010-09-09'
    Description: >-
      Novatrix v47 - Nätverksstack (VPC, två publika och två privata subnät, routing, NACL, security groups).
      Nytt sedan v46: novatrix-public-b (zon b), novatrix-alb-sg, och webbservrarna släpper bara in port 80 från ALB.

    Parameters:
      Prefix:
        Type: String
        Default: novatrix
        AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
        ConstraintDescription: Små bokstäver, siffror och bindestreck (2-21 tecken).
      MyIp:
        Type: String
        Description: Din publika IP i CIDR-format, t.ex. 203.0.113.10/32 (används för SSH vid felsökning).
        AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$'
        ConstraintDescription: Ange en IPv4-adress i CIDR-format, t.ex. 203.0.113.10/32.
      VpcCidr:
        Type: String
        Default: 10.0.0.0/16
      PublicSubnetCidr:
        Type: String
        Default: 10.0.1.0/24
      PublicSubnetBCidr:
        Type: String
        Default: 10.0.3.0/24
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

      PublicSubnetB:
        Type: AWS::EC2::Subnet
        Properties:
          VpcId: !Ref Vpc
          CidrBlock: !Ref PublicSubnetBCidr
          AvailabilityZone: !Select [1, !GetAZs '']
          MapPublicIpOnLaunch: true
          Tags:
            - Key: Name
              Value: !Sub '${Prefix}-public-b'

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

      PublicSubnetBRouteTableAssociation:
        Type: AWS::EC2::SubnetRouteTableAssociation
        Properties:
          SubnetId: !Ref PublicSubnetB
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
      PublicSubnetBNaclAssociation:
        Type: AWS::EC2::SubnetNetworkAclAssociation
        Properties: { SubnetId: !Ref PublicSubnetB, NetworkAclId: !Ref PublicNacl }

      PrivateNacl:
        Type: AWS::EC2::NetworkAcl
        Properties:
          VpcId: !Ref Vpc
          Tags:
            - Key: Name
              Value: !Sub '${Prefix}-private-nacl'

      PrivateInMariaDbFromA:
        Type: AWS::EC2::NetworkAclEntry
        Properties: { NetworkAclId: !Ref PrivateNacl, RuleNumber: 100, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: !Ref PublicSubnetCidr, PortRange: { From: 3306, To: 3306 } }
      PrivateInNfsFromA:
        Type: AWS::EC2::NetworkAclEntry
        Properties: { NetworkAclId: !Ref PrivateNacl, RuleNumber: 110, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: !Ref PublicSubnetCidr, PortRange: { From: 2049, To: 2049 } }
      PrivateInMariaDbFromB:
        Type: AWS::EC2::NetworkAclEntry
        Properties: { NetworkAclId: !Ref PrivateNacl, RuleNumber: 120, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: !Ref PublicSubnetBCidr, PortRange: { From: 3306, To: 3306 } }
      PrivateInNfsFromB:
        Type: AWS::EC2::NetworkAclEntry
        Properties: { NetworkAclId: !Ref PrivateNacl, RuleNumber: 130, Protocol: 6, RuleAction: allow, Egress: false, CidrBlock: !Ref PublicSubnetBCidr, PortRange: { From: 2049, To: 2049 } }
      PrivateOutEphemeralToA:
        Type: AWS::EC2::NetworkAclEntry
        Properties: { NetworkAclId: !Ref PrivateNacl, RuleNumber: 100, Protocol: 6, RuleAction: allow, Egress: true, CidrBlock: !Ref PublicSubnetCidr, PortRange: { From: 1024, To: 65535 } }
      PrivateOutEphemeralToB:
        Type: AWS::EC2::NetworkAclEntry
        Properties: { NetworkAclId: !Ref PrivateNacl, RuleNumber: 110, Protocol: 6, RuleAction: allow, Egress: true, CidrBlock: !Ref PublicSubnetBCidr, PortRange: { From: 1024, To: 65535 } }

      PrivateSubnetANaclAssociation:
        Type: AWS::EC2::SubnetNetworkAclAssociation
        Properties: { SubnetId: !Ref PrivateSubnetA, NetworkAclId: !Ref PrivateNacl }
      PrivateSubnetBNaclAssociation:
        Type: AWS::EC2::SubnetNetworkAclAssociation
        Properties: { SubnetId: !Ref PrivateSubnetB, NetworkAclId: !Ref PrivateNacl }

      AlbSg:
        Type: AWS::EC2::SecurityGroup
        Properties:
          GroupDescription: Load balancer - HTTP 80 from internet
          VpcId: !Ref Vpc
          SecurityGroupIngress:
            - { IpProtocol: tcp, FromPort: 80, ToPort: 80, CidrIp: 0.0.0.0/0 }
          Tags:
            - Key: Name
              Value: !Sub '${Prefix}-alb-sg'

      WebSg:
        Type: AWS::EC2::SecurityGroup
        Properties:
          GroupDescription: Web servers - HTTP 80 only from the load balancer, SSH from MyIp (debugging)
          VpcId: !Ref Vpc
          SecurityGroupIngress:
            - { IpProtocol: tcp, FromPort: 80, ToPort: 80, SourceSecurityGroupId: !Ref AlbSg }
            - { IpProtocol: tcp, FromPort: 22, ToPort: 22, CidrIp: !Ref MyIp }
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
      PublicSubnetBId:
        Value: !Ref PublicSubnetB
        Export: { Name: !Sub '${Prefix}-natverk-PublicSubnetBId' }
      PrivateSubnetAId:
        Value: !Ref PrivateSubnetA
        Export: { Name: !Sub '${Prefix}-natverk-PrivateSubnetAId' }
      PrivateSubnetBId:
        Value: !Ref PrivateSubnetB
        Export: { Name: !Sub '${Prefix}-natverk-PrivateSubnetBId' }
      AlbSgId:
        Value: !Ref AlbSg
        Export: { Name: !Sub '${Prefix}-natverk-AlbSgId' }
      WebSgId:
        Value: !Ref WebSg
        Export: { Name: !Sub '${Prefix}-natverk-WebSgId' }
      DbSgId:
        Value: !Ref DbSg
        Export: { Name: !Sub '${Prefix}-natverk-DbSgId' }
      EfsSgId:
        Value: !Ref EfsSg
        Export: { Name: !Sub '${Prefix}-natverk-EfsSgId' }

### data.yaml

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

### webb.yaml

    AWSTemplateFormatVersion: '2010-09-09'
    Description: >-
      Novatrix v47 - Webbstack: IAM-roll, instance profile och hemligheter.
      Själva servrarna startas av Auto Scaling-gruppen i novatrix-skala (webbservern från v46 är borttagen).

    Parameters:
      Prefix:
        Type: String
        Default: novatrix
        AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
      DataBucket:
        Type: String
        Description: Befintlig data-bucket som servrarna får läsa.
        AllowedPattern: '^[a-z0-9][a-z0-9.-]{2,62}$'
      BackupBucket:
        Type: String
        Description: Befintlig backup-bucket som servrarna får skriva till under backup/.
        AllowedPattern: '^[a-z0-9][a-z0-9.-]{2,62}$'

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

      WpSaltSecret:
        Type: AWS::SecretsManager::Secret
        Properties:
          Description: !Sub 'Seed for WordPress salts, shared by all ${Prefix} web servers'
          GenerateSecretString:
            PasswordLength: 64
            ExcludePunctuation: true
          Tags:
            - Key: Name
              Value: !Sub '${Prefix}-wp-salt-secret'

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
                      - !Ref WpSaltSecret
          Tags:
            - Key: Name
              Value: !Sub '${Prefix}-web-role'

      WebInstanceProfile:
        Type: AWS::IAM::InstanceProfile
        Properties:
          Roles: [!Ref WebRole]

    Outputs:
      InstanceProfileArn:
        Value: !GetAtt WebInstanceProfile.Arn
        Export: { Name: !Sub '${Prefix}-webb-InstanceProfileArn' }
      WpAdminSecretArn:
        Description: Hämta lösenordet med aws secretsmanager get-secret-value
        Value: !Ref WpAdminSecret
        Export: { Name: !Sub '${Prefix}-webb-WpAdminSecretArn' }
      WpSaltSecretArn:
        Value: !Ref WpSaltSecret
        Export: { Name: !Sub '${Prefix}-webb-WpSaltSecretArn' }

### skala.yaml

    AWSTemplateFormatVersion: '2010-09-09'
    Description: >-
      Novatrix v47 - Skalningsstack: Application Load Balancer, target group, listener, launch template
      (WordPress installerar sig själv via user data) och Auto Scaling-grupp över två zoner med target tracking.
      Importerar från novatrix-natverk, novatrix-data och novatrix-webb.

    Parameters:
      Prefix:
        Type: String
        Default: novatrix
        AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
      KeyName:
        Type: AWS::EC2::KeyPair::KeyName
        Description: Key pair för SSH vid felsökning.
      BackupBucket:
        Type: String
        Description: Befintlig backup-bucket (servrarna skriver databasdumpar till backup/).
        AllowedPattern: '^[a-z0-9][a-z0-9.-]{2,62}$'
      InstanceType:
        Type: String
        Default: t3.micro
        AllowedValues: [t3.micro, t3.small, t3.medium]
      LatestAmiId:
        Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
        Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
      MinSize:
        Type: Number
        Default: 2
        MinValue: 1
        Description: Golv. Min 2 ger en server i varje zon.
      MaxSize:
        Type: Number
        Default: 4
        MinValue: 1
        Description: Tak. Sätter övre gräns för kostnaden.
      DesiredCapacity:
        Type: Number
        Default: 2
        MinValue: 1
      TargetCpuUtilization:
        Type: Number
        Default: 50
        MinValue: 10
        MaxValue: 90
        Description: Målvärde för genomsnittlig CPU (target tracking).
      HealthCheckGracePeriod:
        Type: Number
        Default: 600
        Description: >-
          Sekunder innan Auto Scaling-gruppen börjar agera på ohälsa. ALB:ns health checks startar direkt vid registrering
          (servern visas som initial/unhealthy tills sajten svarar), men en ny server får denna tid på sig innan gruppen
          river och ersätter den. Täcker installationen via user data. Skiljer sig från InstanceWarmup, som styr när
          serverns CPU räknas in i skalningen.
      InstanceWarmup:
        Type: Number
        Default: 600
        Description: >-
          Sekunder innan en ny servers CPU räknas in i genomsnittet (target tracking). Ska täcka installationen via user data,
          annars ser policyn den höga CPU:n under installationen som last och kan skala ut i onödan.
      DeregistrationDelay:
        Type: Number
        Default: 30
        Description: Sekunder en server får "dränera" pågående anrop innan den tas bort ur target groupen.
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
      EnableNightSchedule:
        Type: String
        Default: 'false'
        AllowedValues: ['true', 'false']
        Description: >-
          Schemalagd skalning: färre servrar på natten. Spar instanstimmar men ger bara en server (en zon) på natten.
          Stäng av när du kör failover-testet.
      NightCron:
        Type: String
        Default: '0 20 * * *'
        Description: När gruppen går ner till nattstorlek (cron, i tidszonen nedan).
      MorningCron:
        Type: String
        Default: '0 7 * * *'
        Description: När gruppen går tillbaka till normal storlek (varje dag, så att helgen inte blir kvar på natt-läge).
      ScheduleTimeZone:
        Type: String
        Default: Europe/Stockholm
      NightMinSize:
        Type: Number
        Default: 1
        MinValue: 0
      NightDesiredCapacity:
        Type: Number
        Default: 1
        MinValue: 0

    Conditions:
      UseNightSchedule: !Equals [!Ref EnableNightSchedule, 'true']

    Resources:
      LoadBalancer:
        Type: AWS::ElasticLoadBalancingV2::LoadBalancer
        Properties:
          Name: !Sub '${Prefix}-alb'
          Type: application
          Scheme: internet-facing
          IpAddressType: ipv4
          Subnets:
            - Fn::ImportValue: !Sub '${Prefix}-natverk-PublicSubnetId'
            - Fn::ImportValue: !Sub '${Prefix}-natverk-PublicSubnetBId'
          SecurityGroups:
            - Fn::ImportValue: !Sub '${Prefix}-natverk-AlbSgId'
          LoadBalancerAttributes:
            - Key: routing.http.drop_invalid_header_fields.enabled
              Value: 'true'
          Tags:
            - Key: Name
              Value: !Sub '${Prefix}-alb'

      TargetGroup:
        Type: AWS::ElasticLoadBalancingV2::TargetGroup
        Properties:
          Name: !Sub '${Prefix}-web-tg'
          VpcId:
            Fn::ImportValue: !Sub '${Prefix}-natverk-VpcId'
          Protocol: HTTP
          Port: 80
          TargetType: instance
          HealthCheckProtocol: HTTP
          HealthCheckPort: traffic-port
          HealthCheckPath: /wp-login.php
          HealthCheckIntervalSeconds: 15
          HealthCheckTimeoutSeconds: 5
          HealthyThresholdCount: 2
          UnhealthyThresholdCount: 2
          Matcher:
            HttpCode: '200'
          TargetGroupAttributes:
            - Key: deregistration_delay.timeout_seconds
              Value: !Ref DeregistrationDelay
          Tags:
            - Key: Name
              Value: !Sub '${Prefix}-web-tg'

      Listener:
        Type: AWS::ElasticLoadBalancingV2::Listener
        Properties:
          LoadBalancerArn: !Ref LoadBalancer
          Port: 80
          Protocol: HTTP
          DefaultActions:
            - Type: forward
              TargetGroupArn: !Ref TargetGroup

      LaunchTemplate:
        Type: AWS::EC2::LaunchTemplate
        Properties:
          LaunchTemplateName: !Sub '${Prefix}-web-lt'
          LaunchTemplateData:
            ImageId: !Ref LatestAmiId
            InstanceType: !Ref InstanceType
            KeyName: !Ref KeyName
            IamInstanceProfile:
              Arn:
                Fn::ImportValue: !Sub '${Prefix}-webb-InstanceProfileArn'
            SecurityGroupIds:
              - Fn::ImportValue: !Sub '${Prefix}-natverk-WebSgId'
            Monitoring:
              Enabled: true
            MetadataOptions:
              HttpTokens: required
              HttpEndpoint: enabled
            BlockDeviceMappings:
              - DeviceName: /dev/xvda
                Ebs:
                  VolumeType: gp3
                  VolumeSize: 8
                  Encrypted: true
                  DeleteOnTermination: true
            TagSpecifications:
              - ResourceType: instance
                Tags:
                  - Key: Name
                    Value: !Sub '${Prefix}-web'
              - ResourceType: volume
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
                  WP_CONTENT=$WP_DIR/wp-content
                  SITE_URL=http://${AlbDns}

                  dnf install -y aws-cfn-bootstrap
                  signal() { /opt/aws/bin/cfn-signal -e "$1" --stack ${AWS::StackName} --resource AutoScalingGroup --region ${AWS::Region} || true; }
                  trap 'rc=$?; if [ $rc -ne 0 ]; then signal 1; fi' EXIT

                  dnf install -y httpd php php-fpm php-mysqlnd php-gd php-xml php-mbstring \
                    php-intl php-opcache php-cli php-zip mariadb105 amazon-efs-utils jq cronie

                  get_secret() {
                    local v=""
                    for i in 1 2 3 4 5 6; do
                      v=$(aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text) && break
                      sleep 10
                    done
                    [ -n "$v" ] || { echo "FEL: kunde inte läsa hemlighet $1" >&2; exit 1; }
                    echo "$v"
                  }
                  DB_JSON=$(get_secret ${DbSecretArn})
                  DB_USER=$(echo "$DB_JSON" | jq -r .username)
                  DB_PASSWORD=$(echo "$DB_JSON" | jq -r .password)
                  if [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" = "null" ]; then
                    echo "FEL: kunde inte läsa databasuppgifterna" >&2; exit 1
                  fi
                  WP_ADMIN_PASSWORD=$(get_secret ${WpAdminSecretArn})
                  SALT_SEED=$(get_secret ${WpSaltSecretArn})

                  mkdir -p $WP_CONTENT
                  grep -q ${EfsId} /etc/fstab || echo "${EfsId}:/ $WP_CONTENT efs _netdev,noresvport,tls 0 0" >> /etc/fstab
                  for i in 1 2 3 4 5 6; do
                    timeout 90 mount -t efs -o tls ${EfsId}:/ $WP_CONTENT && break
                    sleep 15
                  done
                  mountpoint -q $WP_CONTENT

                  for i in 1 2 3 4 5 6; do
                    MYSQL_PWD="$DB_PASSWORD" mysql --ssl -h ${DbEndpoint} -u "$DB_USER" ${DbName} -e 'SELECT 1' >/dev/null 2>&1 && break
                    sleep 10
                  done
                  MYSQL_PWD="$DB_PASSWORD" mysql --ssl -h ${DbEndpoint} -u "$DB_USER" ${DbName} -e 'SELECT 1' >/dev/null

                  curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
                  chmod +x /usr/local/bin/wp
                  WP="/usr/local/bin/wp --allow-root --path=$WP_DIR"

                  exec 9>"$WP_CONTENT/.novatrix-init.lock"
                  flock -w 1200 9

                  VERSION_FILE=$WP_CONTENT/.novatrix-wp-version
                  if [ -f "$VERSION_FILE" ]; then
                    WP_TARBALL=https://wordpress.org/wordpress-$(cat "$VERSION_FILE").tar.gz
                  else
                    WP_TARBALL=https://wordpress.org/latest.tar.gz
                  fi
                  cd /tmp
                  rm -rf /tmp/wordpress /tmp/wordpress.tar.gz
                  curl -fsSL -o wordpress.tar.gz "$WP_TARBALL"
                  tar -xzf wordpress.tar.gz
                  for f in /tmp/wordpress/*; do
                    [ "$(basename "$f")" = "wp-content" ] || cp -a "$f" $WP_DIR/
                  done
                  if [ ! -f "$VERSION_FILE" ]; then
                    cp -a /tmp/wordpress/wp-content/. $WP_CONTENT/
                    chown -R apache:apache $WP_CONTENT
                    grep -oP "wp_version = '\K[^']+" $WP_DIR/wp-includes/version.php > "$VERSION_FILE"
                  fi
                  rm -rf /tmp/wordpress /tmp/wordpress.tar.gz

                  $WP config create --force --dbname=${DbName} --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" \
                    --dbhost=${DbEndpoint} --dbcharset=utf8mb4 --skip-check
                  for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
                    $WP config set "$k" "$(printf '%s:%s' "$SALT_SEED" "$k" | sha512sum | cut -d' ' -f1)" --type=constant
                  done
                  $WP config set WP_HOME "$SITE_URL" --type=constant
                  $WP config set WP_SITEURL "$SITE_URL" --type=constant
                  $WP config set DISALLOW_FILE_EDIT true --raw --type=constant
                  $WP config set MYSQL_CLIENT_FLAGS MYSQLI_CLIENT_SSL --raw --type=constant

                  if ! $WP core is-installed 2>/dev/null; then
                    $WP core install --url="$SITE_URL" --title="${WpTitle}" \
                      --admin_user="${WpAdminUser}" --admin_password="$WP_ADMIN_PASSWORD" \
                      --admin_email="${WpAdminEmail}" --skip-email
                  fi
                  flock -u 9

                  cat > /etc/httpd/conf.d/novatrix.conf <<'CONF'
                  ServerTokens Prod
                  ServerSignature Off
                  <Directory /var/www/html>
                      Options -Indexes +FollowSymLinks
                      AllowOverride All
                  </Directory>
                  CONF

                  find $WP_DIR -mindepth 1 -maxdepth 1 ! -name wp-content -exec chown -R apache:apache {} +
                  find $WP_DIR -path "$WP_CONTENT" -prune -o -type d -exec chmod 755 {} +
                  find $WP_DIR -path "$WP_CONTENT" -prune -o -type f -exec chmod 644 {} +
                  chown root:apache $WP_DIR/wp-config.php
                  chmod 640 $WP_DIR/wp-config.php

                  cat > /usr/local/bin/novatrix-backup.sh <<'BKP'
                  #!/bin/bash
                  set -euo pipefail
                  export AWS_DEFAULT_REGION=${AWS::Region}
                  WP_CONTENT=/var/www/html/wp-content
                  exec 8>"$WP_CONTENT/.novatrix-backup.lock"
                  flock -n 8 || exit 0
                  MARK="$WP_CONTENT/.novatrix-backup-$(date +%Y%m%d)"
                  [ -f "$MARK" ] && exit 0
                  DB_JSON=$(aws secretsmanager get-secret-value --secret-id ${DbSecretArn} --query SecretString --output text)
                  DB_USER=$(echo "$DB_JSON" | jq -r .username)
                  DB_PASSWORD=$(echo "$DB_JSON" | jq -r .password)
                  TS=$(date +%Y%m%d-%H%M%S)
                  FILE=/tmp/${DbName}-$TS.sql.gz
                  trap 'rm -f "$FILE"' EXIT
                  MYSQL_PWD="$DB_PASSWORD" mysqldump --ssl --host=${DbEndpoint} --user="$DB_USER" \
                    --single-transaction --quick --no-tablespaces ${DbName} | gzip -9 > "$FILE"
                  aws s3 cp "$FILE" "s3://${BackupBucket}/backup/${DbName}-$TS.sql.gz" --only-show-errors
                  touch "$MARK"
                  find "$WP_CONTENT" -maxdepth 1 -name '.novatrix-backup-*' -mtime +30 -delete
                  BKP
                  chmod 750 /usr/local/bin/novatrix-backup.sh
                  echo '0 2 * * * root /usr/local/bin/novatrix-backup.sh >> /var/log/novatrix-backup.log 2>&1' > /etc/cron.d/novatrix-backup

                  systemctl enable --now php-fpm httpd crond
                  /usr/local/bin/novatrix-backup.sh || true

                  code=000
                  for i in $(seq 1 30); do
                    code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/wp-login.php || true)
                    [ "$code" = "200" ] && break
                    sleep 5
                  done
                  [ "$code" = "200" ]

                  trap - EXIT
                  signal 0
                - EfsId:
                    Fn::ImportValue: !Sub '${Prefix}-data-EfsId'
                  DbEndpoint:
                    Fn::ImportValue: !Sub '${Prefix}-data-DbEndpoint'
                  DbName:
                    Fn::ImportValue: !Sub '${Prefix}-data-DbName'
                  DbSecretArn:
                    Fn::ImportValue: !Sub '${Prefix}-data-DbSecretArn'
                  WpAdminSecretArn:
                    Fn::ImportValue: !Sub '${Prefix}-webb-WpAdminSecretArn'
                  WpSaltSecretArn:
                    Fn::ImportValue: !Sub '${Prefix}-webb-WpSaltSecretArn'
                  AlbDns: !GetAtt LoadBalancer.DNSName

      AutoScalingGroup:
        Type: AWS::AutoScaling::AutoScalingGroup
        DependsOn: Listener
        CreationPolicy:
          ResourceSignal:
            Count: !Ref DesiredCapacity
            Timeout: PT25M
        UpdatePolicy:
          AutoScalingRollingUpdate:
            MinInstancesInService: 1
            MaxBatchSize: 1
            PauseTime: PT15M
            WaitOnResourceSignals: true
            SuspendProcesses:
              - HealthCheck
              - ReplaceUnhealthy
              - AZRebalance
              - AlarmNotification
              - ScheduledActions
        Properties:
          AutoScalingGroupName: !Sub '${Prefix}-web-asg'
          LaunchTemplate:
            LaunchTemplateId: !Ref LaunchTemplate
            Version: !GetAtt LaunchTemplate.LatestVersionNumber
          MinSize: !Ref MinSize
          MaxSize: !Ref MaxSize
          DesiredCapacity: !Ref DesiredCapacity
          VPCZoneIdentifier:
            - Fn::ImportValue: !Sub '${Prefix}-natverk-PublicSubnetId'
            - Fn::ImportValue: !Sub '${Prefix}-natverk-PublicSubnetBId'
          TargetGroupARNs:
            - !Ref TargetGroup
          HealthCheckType: ELB
          HealthCheckGracePeriod: !Ref HealthCheckGracePeriod
          MetricsCollection:
            - Granularity: 1Minute
          Tags:
            - Key: Name
              Value: !Sub '${Prefix}-web'
              PropagateAtLaunch: true

      CpuTargetTrackingPolicy:
        Type: AWS::AutoScaling::ScalingPolicy
        Properties:
          AutoScalingGroupName: !Ref AutoScalingGroup
          PolicyType: TargetTrackingScaling
          EstimatedInstanceWarmup: !Ref InstanceWarmup
          TargetTrackingConfiguration:
            PredefinedMetricSpecification:
              PredefinedMetricType: ASGAverageCPUUtilization
            TargetValue: !Ref TargetCpuUtilization

      NightScheduledAction:
        Type: AWS::AutoScaling::ScheduledAction
        Condition: UseNightSchedule
        Properties:
          AutoScalingGroupName: !Ref AutoScalingGroup
          Recurrence: !Ref NightCron
          TimeZone: !Ref ScheduleTimeZone
          MinSize: !Ref NightMinSize
          MaxSize: !Ref MaxSize
          DesiredCapacity: !Ref NightDesiredCapacity

      MorningScheduledAction:
        Type: AWS::AutoScaling::ScheduledAction
        Condition: UseNightSchedule
        Properties:
          AutoScalingGroupName: !Ref AutoScalingGroup
          Recurrence: !Ref MorningCron
          TimeZone: !Ref ScheduleTimeZone
          MinSize: !Ref MinSize
          MaxSize: !Ref MaxSize
          DesiredCapacity: !Ref DesiredCapacity

    Outputs:
      SiteUrl:
        Description: Sajtens adress (lastbalanserarens DNS-namn)
        Value: !Sub 'http://${LoadBalancer.DNSName}/'
      AdminUrl:
        Value: !Sub 'http://${LoadBalancer.DNSName}/wp-admin'
      AlbDnsName:
        Value: !GetAtt LoadBalancer.DNSName
      TargetGroupArn:
        Value: !Ref TargetGroup
      AutoScalingGroupName:
        Value: !Ref AutoScalingGroup
      WpAdminUser:
        Value: !Ref WpAdminUser

### deploy-all.sh

    #!/bin/bash
    # Deployar novatrix-natverk -> novatrix-data -> novatrix-webb -> novatrix-skala (i den ordningen).
    # Användning:  MY_IP=<din-IP>/32 KEY_NAME=novatrix-key bash deploy-all.sh
    # Valfria miljövariabler: PREFIX, DB_CLASS, MIN_SIZE, MAX_SIZE, DESIRED, TARGET_CPU, INSTANCE_TYPE,
    #                         DATA_BUCKET, BACKUP_BUCKET, NIGHT_SCHEDULE=true (färre servrar på natten),
    #                         DISABLE_ROLLBACK=1 (felsökning)
    set -euo pipefail
    export AWS_PAGER=""
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
    export MSYS_NO_PATHCONV=1
    cd "$(dirname "$0")"

    PREFIX="${PREFIX:-novatrix}"
    KEY_NAME="${KEY_NAME:-novatrix-key}"
    DB_CLASS="${DB_CLASS:-db.t3.micro}"
    INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
    MIN_SIZE="${MIN_SIZE:-2}"
    MAX_SIZE="${MAX_SIZE:-4}"
    DESIRED="${DESIRED:-2}"
    TARGET_CPU="${TARGET_CPU:-50}"
    NIGHT_SCHEDULE="${NIGHT_SCHEDULE:-false}"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    DATA_BUCKET="${DATA_BUCKET:-novatrix-data-$ACCOUNT_ID}"
    BACKUP_BUCKET="${BACKUP_BUCKET:-novatrix-backup-$ACCOUNT_ID}"

    if [ -z "${MY_IP:-}" ]; then
      MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')/32"
    fi
    [[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || { echo "FEL: ogiltig MY_IP: $MY_IP"; exit 1; }

    echo "== Förkontroller"
    for t in natverk data webb skala; do
      [ -f "$t.yaml" ] || { echo "FEL: $t.yaml saknas i $(pwd). data.yaml är oförändrad sedan v46: cp ../V46/data.yaml ."; exit 1; }
    done
    for exp in AlbSgId PublicSubnetBId; do
      grep -q "natverk-$exp" natverk.yaml || { echo "FEL: natverk.yaml exporterar inte $exp (behövs av skala.yaml)"; exit 1; }
    done
    for exp in InstanceProfileArn WpAdminSecretArn WpSaltSecretArn; do
      grep -q "webb-$exp" webb.yaml || { echo "FEL: webb.yaml exporterar inte $exp (behövs av skala.yaml)"; exit 1; }
    done
    for exp in EfsId DbEndpoint DbName DbSecretArn; do
      grep -q "data-$exp" data.yaml || { echo "FEL: data.yaml exporterar inte $exp (behövs av skala.yaml)"; exit 1; }
    done

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
    for t in natverk data webb skala; do
      aws cloudformation validate-template --template-body "file://$t.yaml" >/dev/null
      echo "   OK $t.yaml"
    done

    TAGS="Project=$PREFIX ManagedBy=cloudformation"

    echo "== 1/4 Stack $PREFIX-natverk"
    aws cloudformation deploy --stack-name "$PREFIX-natverk" \
      --template-file natverk.yaml \
      --parameter-overrides "Prefix=$PREFIX" "MyIp=$MY_IP" \
      --no-fail-on-empty-changeset --tags $TAGS

    echo "== 2/4 Stack $PREFIX-data (RDS tar ca 5-10 min)"
    aws cloudformation deploy --stack-name "$PREFIX-data" \
      --template-file data.yaml \
      --parameter-overrides "Prefix=$PREFIX" "DbInstanceClass=$DB_CLASS" \
      --no-fail-on-empty-changeset --tags $TAGS

    echo "== 3/4 Stack $PREFIX-webb (roll, instance profile, hemligheter)"
    aws cloudformation deploy --stack-name "$PREFIX-webb" \
      --template-file webb.yaml \
      --capabilities CAPABILITY_IAM \
      --parameter-overrides "Prefix=$PREFIX" "DataBucket=$DATA_BUCKET" "BackupBucket=$BACKUP_BUCKET" \
      --no-fail-on-empty-changeset --tags $TAGS

    echo "== 4/4 Stack $PREFIX-skala (ALB + Auto Scaling; väntar på att servrarna installerat WordPress)"
    ROLLBACK_FLAG=()
    [ "${DISABLE_ROLLBACK:-0}" = "1" ] && ROLLBACK_FLAG=(--disable-rollback)

    aws cloudformation deploy --stack-name "$PREFIX-skala" \
      --template-file skala.yaml \
      ${ROLLBACK_FLAG[@]+"${ROLLBACK_FLAG[@]}"} \
      --parameter-overrides "Prefix=$PREFIX" "KeyName=$KEY_NAME" "BackupBucket=$BACKUP_BUCKET" \
          "InstanceType=$INSTANCE_TYPE" "MinSize=$MIN_SIZE" "MaxSize=$MAX_SIZE" \
          "DesiredCapacity=$DESIRED" "TargetCpuUtilization=$TARGET_CPU" "EnableNightSchedule=$NIGHT_SCHEDULE" \
      --no-fail-on-empty-changeset --tags $TAGS

    out() {
      aws cloudformation describe-stacks --stack-name "$1" \
        --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
    }
    TG_ARN=$(out "$PREFIX-skala" TargetGroupArn)
    SITE_URL=$(out "$PREFIX-skala" SiteUrl)

    echo "== Väntar på att $DESIRED servrar ska bli healthy i target groupen (max 10 min)"
    for _ in $(seq 1 60); do
      HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
        --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
      echo "   healthy: $HEALTHY/$DESIRED"
      [ "$HEALTHY" -ge "$DESIRED" ] && break
      sleep 10
    done

    WP_SECRET_ARN=$(out "$PREFIX-webb" WpAdminSecretArn)
    echo ""
    echo "============================================================"
    echo " KLART! Hela stacken är utrullad som kod, utan manuella steg."
    echo " Webbplats: $SITE_URL"
    echo " Admin:     ${SITE_URL}wp-admin  (användare: novatrix_admin)"
    echo ""
    echo " Admin-lösenord (visas inte här):"
    echo "   aws secretsmanager get-secret-value --secret-id $WP_SECRET_ARN --query SecretString --output text"
    echo ""
    echo " Nästa: bash verify.sh   (sedan lasttest.sh och failover-test.sh)"
    echo "============================================================"

### verify.sh

    #!/bin/bash
    set -e
    export AWS_PAGER=""
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
    PREFIX="${PREFIX:-novatrix}"
    cd "$(dirname "$0")"

    echo "=========================================="
    echo " V47 Verification"
    echo "=========================================="

    echo ""
    echo "== 1. CloudFormation Stackar"
    aws cloudformation list-stacks \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
      --query "StackSummaries[?starts_with(StackName, '$PREFIX')].[StackName,StackStatus]" \
      --output table

    echo ""
    echo "== 2. Target Group Health (förväntar 2 healthy)"
    TG_ARN=$(aws cloudformation describe-stacks --stack-name "$PREFIX-skala" \
      --query "Stacks[0].Outputs[?OutputKey=='TargetGroupArn'].OutputValue" --output text)
    aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query "TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Description]" \
      --output table

    echo ""
    echo "== 3. Auto Scaling Group (Min/Desired/Max)"
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$PREFIX-web-asg" \
      --query "AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize]" --output text

    echo ""
    echo "== 4. Instanser och zoner (bevis på multi-AZ)"
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$PREFIX-web-asg" \
      --query "AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]" \
      --output table

    echo ""
    echo "== 5. Webbplatsen via ALB"
    SITE_URL=$(aws cloudformation describe-stacks --stack-name "$PREFIX-skala" \
      --query "Stacks[0].Outputs[?OutputKey=='SiteUrl'].OutputValue" --output text)
    echo "   URL: $SITE_URL"
    HTTP_CODE=$(curl -s -L -o /dev/null --max-time 15 -w "%{http_code}" "$SITE_URL" 2>/dev/null || true)
    if [[ "$HTTP_CODE" == 200* ]] || [[ "$HTTP_CODE" == 302* ]]; then
      echo "   OK: WordPress svarar med HTTP ${HTTP_CODE:0:3}"
    else
      echo "   FEL: WordPress svarar inte (HTTP: $HTTP_CODE)."
    fi

    echo ""
    echo "== 6. WordPress Admin-lösenord finns i Secrets Manager"
    WP_SECRET=$(aws cloudformation describe-stacks --stack-name "$PREFIX-webb" \
      --query "Stacks[0].Outputs[?OutputKey=='WpAdminSecretArn'].OutputValue" --output text)
    if aws secretsmanager describe-secret --secret-id "$WP_SECRET" >/dev/null 2>&1; then
      echo "   OK: Secret finns"
      echo "   Läs lösenordet med:"
      echo "   aws secretsmanager get-secret-value --secret-id $WP_SECRET --query SecretString --output text"
    else
      echo "   FEL: hemligheten saknas"
    fi

    echo ""
    echo "=========================================="
    echo " Klart! Granska ovanstående utskrifter."
    echo "=========================================="

### lasttest.sh

    #!/bin/bash
    set -uo pipefail
    export AWS_PAGER=""
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
    export MSYS_NO_PATHCONV=1
    cd "$(dirname "$0")" || exit 1

    PREFIX="${PREFIX:-novatrix}"
    ASG="$PREFIX-web-asg"
    MODE="${MODE:-http}"
    KEY_FILE="${KEY_FILE:-}"
    DURATION="${DURATION:-900}"
    CONCURRENCY="${CONCURRENCY:-8}"
    COOLDOWN="${COOLDOWN:-0}"
    OUT="${OUT:-lasttest-$(date +%Y%m%d-%H%M%S).txt}"

    SITE_URL=$(aws cloudformation describe-stacks --stack-name "$PREFIX-skala" \
      --query "Stacks[0].Outputs[?OutputKey=='SiteUrl'].OutputValue" --output text)
    URL="${SITE_URL%/}"
    TG_ARN=$(aws elbv2 describe-target-groups --names "$PREFIX-web-tg" --query 'TargetGroups[0].TargetGroupArn' --output text)

    log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT"; }

    cpu_avg() {
      local v
      v=$(aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
        --dimensions Name=AutoScalingGroupName,Value="$ASG" \
        --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
        --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 60 --statistics Average \
        --query 'sort_by(Datapoints,&Timestamp)[-1].Average' --output text 2>/dev/null || echo None)
      if [ -z "$v" ] || [ "$v" = "None" ]; then echo "-"; else printf '%.0f' "$v"; fi
    }

    PIDS=()
    trap '[ "${#PIDS[@]}" -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null || true' EXIT INT TERM

    log "Start: läge $MODE, $DURATION s (grupp: $ASG, sajt: $URL)"
    log "Före lasten (min, desired, max):"
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
      --query 'AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize]' --output text | tee -a "$OUT"

    if [ "$MODE" = "cpu" ]; then
      [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] || { echo "FEL: MODE=cpu kräver KEY_FILE=~/.ssh/<nyckel>.pem"; exit 1; }
      IPS=$(aws ec2 describe-instances \
        --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].PublicIpAddress' --output text)
      for ip in $IPS; do
        log "Startar CPU-last på $ip (2 processer, $DURATION s)"
        ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ec2-user@$ip" \
          "for n in 1 2; do nohup timeout ${DURATION}s yes > /dev/null 2>&1 < /dev/null & done" \
          || log "VARNING: kunde inte ansluta till $ip (är din IP rätt i MyIp?)"
      done
    else
      for _ in $(seq 1 "$CONCURRENCY"); do
        (
          end=$((SECONDS + DURATION))
          while [ "$SECONDS" -lt "$end" ]; do
            curl -s -o /dev/null -m 20 "$URL/?s=lasttest$RANDOM" || true
          done
        ) &
        PIDS+=($!)
      done
    fi

    STOP=$((SECONDS + DURATION + COOLDOWN))
    while [ "$SECONDS" -lt "$STOP" ]; do
      STATE=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
        --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances[?LifecycleState==`InService`])]' --output text)
      HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
        --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
      # shellcheck disable=SC2086
      set -- $STATE
      log "CPU(medel)=$(cpu_avg)%  desired=$1  inService=$2  healthy=$HEALTHY"
      sleep 30
    done

    log "Klart. Senaste skalningshändelser:"
    aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" --max-items 8 \
      --query 'Activities[].[StartTime,StatusCode,Description]' --output table | tee -a "$OUT"
    log "Lasten är slut. Gruppen skalar in efter ca 15-20 min (larmet AlarmLow kräver lång tid under målet)."
    log "Utskriften är sparad i $OUT"

### failover-test.sh

    #!/bin/bash
    set -uo pipefail
    export AWS_PAGER=""
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
    export MSYS_NO_PATHCONV=1
    cd "$(dirname "$0")" || exit 1

    PREFIX="${PREFIX:-novatrix}"
    ASG="$PREFIX-web-asg"
    OUT="${OUT:-failover-$(date +%Y%m%d-%H%M%S).txt}"

    SITE_URL=$(aws cloudformation describe-stacks --stack-name "$PREFIX-skala" \
      --query "Stacks[0].Outputs[?OutputKey=='SiteUrl'].OutputValue" --output text)
    URL="${SITE_URL%/}"
    TG_ARN=$(aws elbv2 describe-target-groups --names "$PREFIX-web-tg" --query 'TargetGroups[0].TargetGroupArn' --output text)
    log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT"; }

    health_count() {
      aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
        --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
    }

    DESIRED=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
      --query 'AutoScalingGroups[0].DesiredCapacity' --output text)
    HEALTHY=$(health_count)
    log "Sajt: $URL   Grupp: $ASG   Desired: $DESIRED   Healthy nu: $HEALTHY"

    log "Servrar före testet:"
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
      --query "AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]" \
      --output table | tee -a "$OUT"

    VICTIM=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
      --query 'AutoScalingGroups[0].Instances[0].[InstanceId,AvailabilityZone]' --output text)
    VICTIM_ID=$(echo "$VICTIM" | awk '{print $1}')
    VICTIM_AZ=$(echo "$VICTIM" | awk '{print $2}')

    CODES=$(mktemp)
    (
      while [ ! -f /tmp/.stop_failover_test ]; do
        curl -s -o /dev/null -m 10 -w "%{http_code}\n" "$URL/" >> "$CODES" || echo "000" >> "$CODES"
        sleep 1
      done
    ) &
    CURL_PID=$!
    rm -f /tmp/.stop_failover_test

    log "Avslutar server $VICTIM_ID (zon $VICTIM_AZ). curl-loopen mäter sajten under tiden."
    aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$VICTIM_ID" --no-should-decrement-desired-capacity >/dev/null

    START_TIME=$SECONDS
    while true; do
      HEALTHY=$(health_count)
      ELAPSED=$((SECONDS - START_TIME))
      log "healthy=$HEALTHY/$DESIRED  (förfluten tid: $ELAPSED s)"
      
      if [ "$HEALTHY" -ge "$DESIRED" ]; then
        log "Återhämtad: $DESIRED servrar är healthy igen efter $ELAPSED s, utan manuell handpåläggning."
        break
      fi
      if [ "$ELAPSED" -gt 300 ]; then
        log "FEL: Timeout efter 5 minuter. Något är fel."
        break
      fi
      sleep 15
    done

    touch /tmp/.stop_failover_test
    sleep 2
    kill "$CURL_PID" 2>/dev/null || true
    rm -f /tmp/.stop_failover_test

    log "Servrar efter testet (ersättaren kan ligga i någon av zonerna):"
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
      --query "AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]" \
      --output table | tee -a "$OUT"

    TOTAL=$(wc -l < "$CODES")
    FAILS=$(grep -cv '^200$' "$CODES" || true)
    log "Svarskoder från curl-loopen under hela testet (antal per kod):"
    sort "$CODES" | uniq -c | tee -a "$OUT"
    log "Anrop som inte gav 200: $FAILS av $TOTAL"
    rm -f "$CODES"

    log "Skalningshändelser:"
    aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" --max-items 6 \
      --query 'Activities[].[StartTime,StatusCode,Description]' --output table | tee -a "$OUT"
    log "Utskriften är sparad i $OUT"

### teardown-v47.sh

    #!/bin/bash
    # Rensar allt som deploy-all.sh skapat: stackarna i omvänd ordning (skala -> webb -> data -> natverk),
    # därefter de två S3-buckets, och kontrollerar sist att inget som kostar pengar finns kvar.
    # Skala-stacken först, annars startar gruppen nya servrar medan du river.
    #
    # Användning:  bash teardown-v47.sh
    # Valfria variabler: YES=1 (hoppa över bekräftelsen), KEEP_BUCKETS=1 (behåll buckets), PREFIX
    # Skriptet går att köra om om något fastnar: det hoppar över stackar som redan är borta.
    set -uo pipefail
    export AWS_PAGER=""
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
    export MSYS_NO_PATHCONV=1
    cd "$(dirname "$0")" || exit 1

    PREFIX="${PREFIX:-novatrix}"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || exit 1
    DATA_BUCKET="${DATA_BUCKET:-novatrix-data-$ACCOUNT_ID}"
    BACKUP_BUCKET="${BACKUP_BUCKET:-novatrix-backup-$ACCOUNT_ID}"

    if [ "${YES:-0}" != "1" ]; then
      echo "VARNING: detta raderar stackarna $PREFIX-skala, $PREFIX-webb, $PREFIX-data och $PREFIX-natverk"
      echo "(inklusive databasen, utan slutsnapshot) och, om inte KEEP_BUCKETS=1, tömmer och tar bort"
      echo "$DATA_BUCKET och $BACKUP_BUCKET med alla backuper."
      read -r -p "Skriv 'radera' för att fortsätta: " ANS
      [ "$ANS" = "radera" ] || { echo "Avbryter."; exit 1; }
    fi

    stack_exists() {
      aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1
    }

    show_failures() {
      echo "   Resurser som misslyckades i $1:"
      aws cloudformation describe-stack-events --stack-name "$1" \
        --query "StackEvents[?contains(ResourceStatus, 'FAILED')].[LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
        --output table 2>/dev/null | head -20
    }

    delete_stack() {
      local s=$1 attempt
      if ! stack_exists "$s"; then
        echo "   = $s finns inte"
        return 0
      fi
      for attempt in 1 2; do
        echo "   Tar bort $s (försök $attempt)..."
        aws cloudformation delete-stack --stack-name "$s"
        if aws cloudformation wait stack-delete-complete --stack-name "$s"; then
          echo "   OK: $s borttagen"
          return 0
        fi
        show_failures "$s"
        if [ "$attempt" = "1" ]; then
          echo "   Väntar 2 min och försöker igen (nätverkskort från lastbalanseraren släpps med fördröjning)..."
          sleep 120
        fi
      done
      echo "FEL: $s kunde inte tas bort. Åtgärda orsaken ovan och kör skriptet igen."
      return 1
    }

    echo "== Riv stackarna i omvänd ordning"
    for s in "$PREFIX-skala" "$PREFIX-webb" "$PREFIX-data" "$PREFIX-natverk"; do
      delete_stack "$s" || exit 1
    done

    if [ "${KEEP_BUCKETS:-0}" = "1" ]; then
      echo "== S3-buckets lämnas kvar (KEEP_BUCKETS=1)"
    else
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
    fi

    echo "== Kontrollerar att inget som kostar pengar finns kvar"
    LEFT=0
    check() {   # check <beskrivning> <kommandoutskrift>
      if [ -n "$2" ] && [ "$2" != "None" ]; then
        echo "   KVAR: $1: $2"
        LEFT=1
      else
        echo "   ok: inga $1"
      fi
    }
    check "lastbalanserare" "$(aws elbv2 describe-load-balancers --names "$PREFIX-alb" --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)"
    check "Auto Scaling-grupper" "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$PREFIX-web-asg" --query 'AutoScalingGroups[].AutoScalingGroupName' --output text 2>/dev/null)"
    check "servrar" "$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$PREFIX-web" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
    check "databaser" "$(aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier, '$PREFIX-data')].DBInstanceIdentifier" --output text 2>/dev/null)"
    check "EFS-filsystem" "$(aws efs describe-file-systems --query "FileSystems[?Name=='$PREFIX-efs'].FileSystemId" --output text 2>/dev/null)"
    if [ "${KEEP_BUCKETS:-0}" != "1" ]; then
      for bucket in "$DATA_BUCKET" "$BACKUP_BUCKET"; do
        aws s3api head-bucket --bucket "$bucket" 2>/dev/null && { echo "   KVAR: bucket $bucket"; LEFT=1; }
      done
    fi

    if [ "$LEFT" = "0" ]; then
      echo "Klart. Allt är borta (VPC, subnät, hemligheter och larm togs bort med stackarna)."
    else
      echo "Något finns kvar, se ovan. Kör skriptet igen eller ta bort resursen i konsolen."
      exit 1
    fi