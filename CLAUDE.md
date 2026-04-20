# doraby.github.io

## Deployment

All changes must be merged and pushed to `main` to go live at https://doraby.github.io/pogoda/

After any commit on a feature branch, always run:
```
git checkout main && git merge <branch> --ff-only && git push origin main
```
