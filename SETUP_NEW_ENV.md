# Copy project to a new environment

## Option 1: Copy as archive
```bash
tar -czf deploy-helper.tar.gz .
# move file to new env
# then on new env:
tar -xzf deploy-helper.tar.gz
```

## Option 2: Git clone (recommended)
```bash
git clone <your-repo-url> Deploy-helper
cd Deploy-helper
```

## Run in new env
```bash
mvn -q test
mvn quarkus:dev
```

Default app URL: `http://localhost:8080`
