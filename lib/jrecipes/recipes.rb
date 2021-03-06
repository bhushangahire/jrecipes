Capistrano::Configuration.instance(:must_exist).load do

  # We don't need to know the repository since it won't be accessed
  set :repository, ""

  # Set the default deploy method to war_file
  set :deploy_via, :war_file
  # Allow another round of update_code with another strategy
  set :deploy_via_secondary, nil

  # Set the defaults for tomcat deployment
  set :app_server, :tomcat
  set :war_file, defer { "#{application}.war" }
  set :tomcat_path, "/opt/tomcat"
  set :tomcat_webapp, "ROOT"
  set :tomcat_run_method, defer { fetch(:run_method, :sudo) }
  set :tomcat_options, ""
  set :class_path, ""

  namespace :deploy do
    desc <<-DESC
      Run the migrate rake task locally. By default, this will use your current \
      database.yml configuration. However, you can specify a different database \
      config via the migrate_config variable. Make sure to have access to your \
      database server from the machine you're deploying from. You can specify \
      additional environment variables to pass to rake via the migrate_env \
      variable. Finally, you can specify the full path to the rake executable by \
      setting the rake variable. The defaults are:

        set :rake,           "rake"
        set :rails_env,      "production"
        set :migrate_env,    ""
        set :migrate_config, "config/database.yml"
    DESC
    task :migrate, :roles => :db, :only => { :primary => true } do
      rake = fetch(:rake, "rake")
      rails_env = fetch(:rails_env, "production")
      migrate_env = fetch(:migrate_env, "")
      migrate_config = fetch(:migrate_config, "config/database.yml")

      if migrate_config != "config/database.yml"
        File.cp "config/database.yml", "config/database_cap_backup.yml"
        File.cp migrate_config, "migrate_config"
      end

      system("#{rake} RAILS_ENV=#{rails_env} #{migrate_env} db:migrate")

      if migrate_config != "config/database.yml"
        File.mv "config/database_cap_backup.yml", "config/database.yml"
      end
    end

    desc <<-DESC
      Copies your project to the remote servers. This is the first stage \
      of any deployment; moving your updated code and assets to the deployment \
      servers. You will rarely call this task directly, however; instead, you \
      should call the `deploy' task (to do a complete deploy) or the `update' \
      task (if you want to perform the `restart' task separately).

      JRecipes sets the default deployment strategy to :war_file which creates \
      a war file locally and uploads it to the release path. However, you \
      might want to do a regular checkout or other form of code update, in \
      order to have your full project in your release path. If you want this \
      set the :deploy_via_secondary variable to the strategy that this should \
      use, and make sure you set the :scm variable to the source control \
      software you are using (it defaults to :subversion).
    DESC
    task :update_code, :except => { :no_release => true } do
      on_rollback { run "rm -rf #{release_path}; true" }
      # We do the secondary strategy first since it might expect that the
      # release_path doesn't exist
      if deploy_via_secondary and deploy_via_secondary.to_sym != deploy_via.to_sym
        Capistrano::Deploy::Strategy.new(deploy_via_secondary, self).deploy!
      end
      strategy.deploy!
      finalize_update
    end

    desc "[internal] Runs app server specific symlink task."
    task :app_server_symlink, :roles => :app do
      begin
        find_and_execute_task("#{app_server}:symlink")
      rescue Capistrano::NoSuchTaskError
        # rescue NoSuchTaskError silently
      end
    end
    after "deploy:symlink", "deploy:app_server_symlink"

    %w{start stop restart}.each do |task_name|
      desc "Runs app server specific #{task_name} task."
      task task_name.to_sym, :roles => :app do
        find_and_execute_task("#{app_server}:#{task_name}")
      end
    end

    namespace :rollback do
      desc "[internal] Runs app server specific rollback task."
      task :app_server_rollback, :roles => :app do
        begin
          find_and_execute_task("#{app_server}:rollback")
        rescue Capistrano::NoSuchTaskError
          # rescue NoSuchTaskError silently
        end
      end
      after "deploy:rollback:revision", "deploy:rollback:app_server_rollback"
    end
  end

  namespace :tomcat do
    desc "Start Tomcat"
    task :start, :roles => :app do
      invoke_command <<-CMD, :via => tomcat_run_method
        sh -c '
          cd "#{tomcat_path}" &&
          CLASSPATH="$CLASSPATH#{":#{class_path}" unless class_path.empty?}"
          JAVA_OPTS="#{tomcat_options}" bin/startup.sh
        '
      CMD
    end

    desc "Stop Tomcat"
    task :stop, :roles => :app do
      invoke_command <<-CMD, :via => tomcat_run_method
        sh -c '
          cd "#{tomcat_path}" && bin/shutdown.sh
        '
      CMD
    end

    desc "Restart Tomcat"
    task :restart, :roles => :app do
      tomcat.stop
      # Waiting for Tomcat shutdown
      invoke_command <<-CMD, :via => tomcat_run_method
        sh -c '
          cd "#{tomcat_path}" &&
          while ! tail -n 4 logs/catalina.out | grep -q "Stopping Coyote"; do
            sleep 0.5;
          done
        '
      CMD
      tomcat.remove_deployed
      tomcat.start
    end

    desc "Removes the deployed webapp from Tomcat"
    task :remove_deployed, :roles => :app do
      invoke_command "rm -rf #{tomcat_path}/webapps/#{tomcat_webapp}", :via => tomcat_run_method
    end

    desc "Copies the war file into Tomcat's webapps directory"
    task :copy, :roles => :app do
      invoke_command "cp #{current_path}/#{war_file} #{tomcat_path}/webapps/#{tomcat_webapp}.war", :via => tomcat_run_method
    end

    desc <<-DESC
      [internal] Symlink app from current release into Tomcat's webapps \
      directory it it's not already there."
    DESC
    task :symlink, :roles => :app do
      link = "#{tomcat_path}/webapps/#{tomcat_webapp}.war"
      target = "#{current_path}/#{war_file}"
      invoke_command %{ln -snf "#{target}" "#{link}"}, :via => tomcat_run_method
    end
  end
end
