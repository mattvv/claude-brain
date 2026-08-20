Ops says the service still logs at debug level in production even though they
set level = "warn" under [logging.production]. The loader reads this file, then
applies the section named by APP_ENV, then env vars. APP_ENV=production is set.
What in this file explains the behavior, and how should it be fixed?
