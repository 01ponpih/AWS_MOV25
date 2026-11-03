#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "== 1/3: Nätverk =="
bash vpc.sh

echo "== 2/3: Identitet och lagring =="
bash roller.sh

echo "== 3/3: Servrar =="
bash servers.sh

echo "====================================================="
echo "Klart! Verifiera nätverket med:"
echo "bash verify-net.sh ../V42/novatrix-key.pem"
echo "====================================================="