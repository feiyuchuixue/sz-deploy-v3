# TYPE  DATABASE        USER                         ADDRESS                 METHOD
local   all             all                                                 scram-sha-256
host    all             all                          127.0.0.1/32            scram-sha-256
host    all             all                          ::1/128                 scram-sha-256

# sz network internal access
host    ${PG_DB_NAME}   ${PG_INTERNAL_USER}         ${PG_INTERNAL_SUBNET}    scram-sha-256

# deny all other remote access
host    all             all                          0.0.0.0/0               reject
host    all             all                          ::/0                    reject
