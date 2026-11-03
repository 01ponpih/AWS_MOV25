#!/bin/bash
dnf update -y
dnf install -y httpd
systemctl start httpd
systemctl enable httpd

cat << 'HTML' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="sv">
<head>
    <meta charset="UTF-8">
    <title>Novatrix AB</title>
</head>
<body>
    <h1>Novatrix AB</h1>
    <p>Vi bygger moderna digitala system f&ouml;r f&ouml;retag som vill v&auml;xa.</p>
    <p>Denna server k&ouml;rs i ett eget VPC med defense in depth.</p>
</body>
</html>
HTML