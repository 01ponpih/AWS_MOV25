# AWS Uppgift 1 (v42)

## Delmoment 1: Sätt upp kursrepo på GitHub
Skapat ett publikt GitHub-repository för kursen där källkod, konfigurationsfiler och dokumentation samlas. En `README.md` med namn, kursnamn och veckans rubrik ligger i roten av repot.

* **Repository:** https://github.com/01ponpih/AWS_MOV25

**Verifiering:** Repot är publikt och går att komma åt via webbläsaren utan inloggning.

---

## Delmoment 2: Provisionera en EC2-instans
Startade en Linux-server i AWS åt Novatrix AB med följande inställningar:

* **AMI:** Amazon Linux 2023
* **Instanstyp:** `t3.micro` 
* **Key Pair:** `novatrix-key.pem` (sparad lokalt i `~/.ssh` med begränsade rättigheter)
* **Security Group:**
  * **SSH (Port 22):** Endast öppen för min egen IP.
  * **HTTP (Port 80):** Öppen mot `0.0.0.0/0` så att webbservern kan nås publikt.

**Verifiering:** Instansen visar status "Running" och "2/2 checks passed" i AWS-konsolen.

---

## Delmoment 3: Konfigurera värdmiljön
Anslöt till servern via SSH (Git Bash) och installerade webbservern Apache (`httpd`).

```bash
# Anslut till servern
ssh -i ~/.ssh/novatrix-key.pem ec2-user@13.51.72.219

# Uppdatera paket och installera Apache
sudo dnf update -y
sudo dnf install -y httpd

# Starta Apache och aktivera automatisk start vid omstart
sudo systemctl start httpd
sudo systemctl enable httpd
```

**Verifiering:** Körde kommandot `sudo systemctl status httpd` vilket visade att tjänsten körs.

---

## Delmoment 4: Driftsätt applikationen
Skapade en enkel webbsida för Novatrix AB i Apaches standardkatalog (`/var/www/html/index.html`).

```bash
echo '<h1>Välkommen till Novatrix AB</h1><p>Servern körs på AWS EC2!</p>' | sudo tee /var/www/html/index.html
```

**Verifiering:** Körde `cat /var/www/html/index.html` på servern för att bekräfta att filen hade skapats med rätt innehåll.

---

## Delmoment 5: Verifiera och dokumentera

### 1. Lokal verifiering via SSH
Körde `curl` internt på servern för att kontrollera att Apache svarar korrekt på port 80:

```bash
curl localhost
```

### 2. Publik verifiering i webbläsare
Sidan bekräftades nåbar externt via webbläsaren på instansens publika IP-adress:  
`http://13.51.72.219`

![alt text](image.png)
![alt text](<Skärmbild 2026-10-19 201706.png>)
![alt text](<Skärmbild 2026-10-19 201813.png>)

---

## Delmoment 6: Kostnadskontroll (AWS Budgets)
Skapade en budget i AWS Budgets för att förhindra oväntade kostnader:

* **Budgetnamn:** `Monthly Budget`
* **Månadsbudget:** 10 USD
* **Larm 1 (Actual / Faktisk):** E-postvarning skickas vid **85%** av den faktiska kostnaden.
* **Larm 2 (Actual / Faktisk):** E-postvarning skickas vid **100%** av den faktiska kostnaden.
* **Larm 3 (Forecasted / Prognostiserad):** E-postvarning skickas om den prognostiserade månadskostnaden förväntas nå **100%**.

---

## VG

I stället för att klicka fram instansen i AWS-konsolen har jag lagt allt i skript, så att samma miljö kan sättas upp igen utan att man behöver komma ihåg varje steg. Skripten ligger i mappen `V42` i repot.

### Filer

* **`provision.sh`** skapar nyckelpar och säkerhetsgrupp och startar instansen. Den hämtar senaste Amazon Linux 2023 automatiskt, så jag slipper hålla koll på AMI-ID:n. Port 22 låses till min egen IP och port 80 är öppen för alla. Skriptet avbryter om en instans med samma namn redan körs, så att man inte startar dubbletter av misstag.
* **`userdata.sh`** skickas med när servern startar. Den installerar Apache och skriver HTML-filen. `curl` visade å, ä och ö fel i Git Bash, trots att webbläsaren visade dem rätt. Därför använder sidan HTML-entiteter (`&auml;` osv), så att texten blir rätt oavsett teckenkodning.
* **`teardown.sh`** tar bort instansen, säkerhetsgruppen och nyckelparet, så att man inte betalar för något man glömt.

### Skyddsfiler

* **`.gitignore`** ser till att den privata nyckeln (`*.pem`) aldrig laddas upp till GitHub.
* **`.gitattributes`** tvingar Git att spara skripten med Linux-radbrytningar (LF). Annars kan de krascha om någon klonar repot på en Windows-dator, eftersom Windows kan lägga till CRLF.

### Förutsättningar

För att kunna köra skripten krävs följande:

* **AWS CLI v2** installerat. Kontrollera med `aws --version`.
* **IAM-användare** med behörigheterna `AmazonEC2FullAccess` och `AmazonSSMReadOnlyAccess`. Root-kontot används inte för CLI.
* **Inloggning och region** konfigurerade:

```bash
aws configure
aws sts get-caller-identity
```

Region ska vara `eu-north-1` (Stockholm).

### Så återskapas miljön från repot

```bash
git clone https://github.com/01ponpih/AWS_MOV25
cd AWS_MOV25/V42
bash provision.sh
```

Skriptet skriver ut en adress i formen `http://<IP>`. Det kan ta ungefär en minut efter att skriptet är klart innan Apache svarar.

### Verifiering

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=novatrix-web-vg" \
  --query 'Reservations[].Instances[].State.Name' --output text
curl http://<IP>
```

Det första kommandot ska ge `running`. `curl` ska returnera HTML-sidan, och i webbläsaren ska texten med å, ä och ö visas korrekt. Jag testade både `curl` och webbläsaren.

**Screenshot på automatiserad driftsättning:**
Nedan visas sidan som skapades helt automatiskt av `userdata.sh`:

![alt text](<Skärmbild 2026-10-20 135049.png>)

### Städning

```bash
bash teardown.sh
```

Därefter kontrollerade jag i EC2-konsolen att inga instanser eller säkerhetsgrupper fanns kvar.

### Begränsningar

* SSH är öppen bara för min IP. Ändras den måste regeln uppdateras.
* Sidan körs på HTTP utan certifikat, så webbläsaren visar "Inte säker".
* Allt skapas i default-VPC i Stockholm. Lösningen är ett första steg mot IaC i v46.