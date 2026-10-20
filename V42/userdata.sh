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
    <h1>V&auml;lkommen till Novatrix AB</h1>
    <p>Vi erbjuder innovativa tekniska l&ouml;sningar f&ouml;r f&ouml;retag som vill v&auml;xa digitalt.</p>
    <p>Denna server &auml;r provisionerad helt via AWS CLI och User Data.</p>
</body>
</html>
HTML