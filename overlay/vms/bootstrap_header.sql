-- First lines of the bootstrap SQL (vms/install_db.com), as
-- scripts/mariadb-install-db writes them with --auth-root-authentication-method=normal.
create database if not exists mysql;
use mysql;
SET @auth_root_socket=NULL;
