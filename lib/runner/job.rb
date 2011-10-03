require File.expand_path(File.join(File.dirname(__FILE__), 'runner.rb'))

module Testbot::Runner
  class Job
    attr_reader :root, :project, :requester_mac, :git_hash, :git_repo, :build_id

    def initialize(runner, id, requester_mac, project, root, type, ruby_interpreter, files, git_hash, git_repo, build_id)
      @runner, @id, @requester_mac, @project, @root, @type, @ruby_interpreter, @files, @git_hash, @git_repo, @build_id =
        runner, id, requester_mac, project, root, type, ruby_interpreter, files, git_hash, git_repo, build_id
    end

    def jruby?
      @ruby_interpreter == 'jruby'
    end

    def run(instance)
      puts "Running job #{@id} from #{@requester_mac}... "
      test_env_number = (instance == 0) ? '' : instance + 1
      result = "\n#{`hostname`.chomp}:#{Dir.pwd}\n"
      base_environment = "export RAILS_ENV=test; export TEST_ENV_NUMBER=#{test_env_number}; cd #{@project};"

      adapter = Adapter.find(@type)
      failed_tests = nil
      success = false
      run_time = measure_run_time do
        result += run_and_return_result("#{base_environment} #{adapter.command(@project, ruby_cmd, @files, test_env_number)}")
        success = ($?.exitstatus == 0)
        if adapter.rerunnable? && !success
          failed_tests = `cat #{@project}/rerun_#{test_env_number}.txt`
          puts "Failed tests: #{failed_tests}"
        end
      end

      Server.put("/jobs/#{@id}", :body => { :result => result, :success => success, :rerun => failed_tests, :time => run_time })
      puts "Job #{@id} finished."
    end

    private

    def measure_run_time
      start_time = Time.now
      yield
      (Time.now - start_time) * 100
    end

    def run_and_return_result(command)
      `#{command} 2>&1`
    end

    def ruby_cmd
      if @ruby_interpreter == 'jruby' && @runner.config.jruby_opts
        'jruby ' + @runner.config.jruby_opts
      else
        @ruby_interpreter
      end
    end
  end
end
