Rails.application.routes.draw do
  get "configuration/boot"
  get "configuration/download_client_config"
  get "configuration/download_voting_database"
  post "configuration/upload_client_config"
  post "configuration/upload_ballot_data"
  post "configuration/import_new_sql"
  delete "configuration/clear_votes"
end
