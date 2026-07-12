#!/usr/bin/env bash
set -euo pipefail

DB_PASS="${DB_PASS:?DB_PASS is required}"

PG_CONF=/etc/postgresql/13/main/postgresql.conf
PG_HBA=/etc/postgresql/13/main/pg_hba.conf

cat >>"$PG_CONF" <<'EOF'

# liquid benchmark
listen_addresses = '*'
EOF

cat >>"$PG_HBA" <<'EOF'

# liquid benchmark
host all all 0.0.0.0/0 md5
host all all ::/0 md5
EOF

systemctl restart postgresql || pg_ctlcluster 13 main restart
sudo -u postgres psql -v ON_ERROR_STOP=1 \
  -c "DROP ROLE IF EXISTS bench" \
  -c "CREATE ROLE bench LOGIN SUPERUSER PASSWORD '${DB_PASS}'"

MYSQL_CNF=/etc/mysql/mariadb.conf.d/50-server.cnf
if grep -q '^bind-address' "$MYSQL_CNF"; then
  sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$MYSQL_CNF"
else
  cat >>"$MYSQL_CNF" <<'EOF'

[mysqld]
bind-address = 0.0.0.0
EOF
fi

systemctl restart mariadb
mysql -uroot <<SQL
DROP USER IF EXISTS 'bench'@'%';
CREATE USER 'bench'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'bench'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

FB_PASS="$(awk -F= '/ISC_PASSWORD/ {gsub(/"/, "", $2); print $2}' /etc/firebird/3.0/SYSDBA.password 2>/dev/null || true)"
if [[ -n "$FB_PASS" ]]; then
  /usr/bin/gsec -user sysdba -password "$FB_PASS" -modify sysdba -pw "$DB_PASS" || true
fi

mkdir -p /var/lib/firebird/3.0/data
chown -R firebird:firebird /var/lib/firebird/3.0/data
systemctl restart firebird3.0 || true

ss -ltnp | grep -E ':(3050|3306|5432)\b' || true
df -P /home/pi/liquidstoolap-bench/dbdata /var/lib/postgresql /var/lib/mysql /var/lib/firebird/3.0/data 2>/dev/null || true
