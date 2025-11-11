Review 1_DEV_README.md to ensure kubectl is working locally

Files Gitignored:

-   specify_uat_dump.sql. Dev sql file is included to test specify loads locally via kubernetes
-   All .env files. Use .env.template to create env files for each overlay
-   kustomize/creds folder: contains creds for each overlay
    -   creds/dev: dev user and pass for specify_dev_dump.sql located in base folder - also gitignored
    -   creds/uat: uat it_user and master_user txt files with host server info
    -   creds/prod: prod it_user and master_user txt files with host server info

Enable and use the reset script:

-   chmod +x reset.sh
-   ./reset-specify.sh
