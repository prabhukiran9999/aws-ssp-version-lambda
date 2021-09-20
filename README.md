testing :

curl "$(terraform output -raw base_url)/api/v1/greeting/latest"