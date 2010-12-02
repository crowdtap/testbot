require 'rubygems'
require 'httparty'
require 'macaddr'
require 'ostruct'
require File.dirname(__FILE__) + '/shared/ssh_tunnel'
require File.dirname(__FILE__) + '/adapters/adapter'

TIME_BETWEEN_NORMAL_POLLS = 1
TIME_BETWEEN_QUICK_POLLS = 0.1
TIME_BETWEEN_PINGS = 5
TIME_BETWEEN_VERSION_CHECKS = 60
MAX_CPU_USAGE_WHEN_IDLE = 50

class CPU

 def self.current_usage
   process_usages = `ps -eo pcpu`
   total_usage = process_usages.split("\n").inject(0) { |sum, usage| sum += usage.strip.to_f }
   (total_usage / count).to_i
 end

 def self.count
   case RUBY_PLATFORM
     when /darwin/
       `hwprefs cpu_count`.to_i
     when /linux/
       `cat /proc/cpuinfo | grep processor | wc -l`.to_i
   end
 end

end

class Job
  attr_reader :root, :project, :requester_mac
    
  def initialize(runner, id, requester_mac, project, root, type, ruby_interpreter, files)
    @runner, @id, @requester_mac, @project, @root, @type, @ruby_interpreter, @files =
         runner, id, requester_mac, project, root, type, ruby_interpreter, files
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
    result += `#{base_environment} #{adapter.command(@project, ruby_cmd, @files)} 2>&1`

    Server.put("/jobs/#{@id}", :body => { :result => result, :success => ($?.exitstatus == 0) })
    puts "Job #{@id} finished."
  end
  
  private
  
  def ruby_cmd
    if @ruby_interpreter == 'jruby' && @runner.config.jruby_opts
      'jruby ' + @runner.config.jruby_opts
    else
      @ruby_interpreter
    end
  end
end

class Server
  include HTTParty
end

class Runner

  def initialize(config)
    @instances = []
    @last_requester_mac = nil
    @last_version_check = Time.now - TIME_BETWEEN_VERSION_CHECKS - 1
    @config = OpenStruct.new(config)
    @config.max_instances = @config.max_instances ? @config.max_instances.to_i : CPU.count 
    
    if @config.ssh_tunnel
      server_uri = "http://127.0.0.1:#{Testbot::SERVER_PORT}"
    else
      server_uri = "http://#{@config.server_host}:#{Testbot::SERVER_PORT}"
    end
    
    Server.base_uri(server_uri)
  end
  
  attr_reader :config
  
  def run!
    # Remove legacy instance* and *_rsync|git style folders
    Dir.entries(".").find_all { |name| name.include?('instance') || name.include?('_rsync') ||
                                       name.include?('_git') }.each { |folder|
      system "rm -rf #{folder}"
    }
    
    SSHTunnel.new(@config.server_host, @config.server_user || Testbot::DEFAULT_USER).open if @config.ssh_tunnel
    while true
      begin
        update_uid!
        start_ping
        wait_for_jobs
      rescue Exception => ex
        break if [ 'SignalException', 'Interrupt' ].include?(ex.class.to_s)
        puts "The runner crashed, restarting. Error: #{ex.inspect} #{ex.class}"
      end
    end
  end

  private
  
  def update_uid!
    # When a runner crashes or is restarted it might loose current job info. Because
    # of this we provide a new unique ID to the server so that it does not wait for
    # lost jobs to complete.
    @uid = "#{Time.now.to_i}@#{Mac.addr}"
  end
  
  def wait_for_jobs
    last_check_found_a_job = false
    loop do
      sleep (last_check_found_a_job ? TIME_BETWEEN_QUICK_POLLS : TIME_BETWEEN_NORMAL_POLLS)

      check_for_update if !last_check_found_a_job && time_for_update?

      # Only get jobs from one requester at a time
      next_params = base_params
      if @instances.size > 0
        next_params.merge!({ :requester_mac => @last_requester_mac })
        next_params.merge!({ :no_jruby => true }) if max_jruby_instances?
      else
        @last_requester_mac = nil
      end
      
      # Makes sure all instances are listed as available after a run
      clear_completed_instances 
      next unless cpu_available?
      
      next_job = Server.get("/jobs/next", :query => next_params) rescue nil
      next if next_job == nil
      last_check_found_a_job = true

      job = Job.new(*([ self, next_job.split(',') ].flatten))
      if first_job_from_requester?
        fetch_code(job)
        before_run(job) if File.exists?("#{job.project}/lib/tasks/testbot.rake")
      end
      
      @instances << [ Thread.new { job.run(free_instance_number) },
                      free_instance_number, job ]
      @last_requester_mac = job.requester_mac
      loop do
        clear_completed_instances
        break unless max_instances_running?
      end
    end
  end
  
  def max_jruby_instances?
    return unless @config.max_jruby_instances
    @instances.find_all { |thread, n, job| job.jruby? }.size >= @config.max_jruby_instances
  end
  
  def fetch_code(job)
    system "rsync -az --delete -e ssh #{job.root}/ #{job.project}"
  end
  
  def before_run(job)
    bundler_cmd = RubyEnv.bundler?(job.project) ? "bundle; " : ""
    system "export RAILS_ENV=test; export TEST_INSTANCES=#{@config.max_instances}; cd #{job.project}; #{bundler_cmd} rake testbot:before_run"
  end
  
  def first_job_from_requester?
    @last_requester_mac == nil
  end
  
  def cpu_available?
    @instances.size > 0 || CPU.current_usage < MAX_CPU_USAGE_WHEN_IDLE
  end
  
  def time_for_update?
    time_for_update = ((Time.now - @last_version_check) >= TIME_BETWEEN_VERSION_CHECKS)
    @last_version_check = Time.now if time_for_update
    time_for_update
  end
  
  def check_for_update
    return unless @config.auto_update
    version = Server.get('/version') rescue Testbot::VERSION
    return unless version != Testbot::VERSION

    successful_install = system "gem install testbot -v #{version}"

    if successful_install
      File.open("/tmp/update_testbot.sh", "w") { |file| file.write("#!/bin/sh\nsleep 5\ntestbot #{ARGV.join(' ')}") }
      system "chmod +x /tmp/update_testbot.sh"
      system "nohup /tmp/update_testbot.sh &"
      exit 0
    end
  end

  def ping_params
    { :hostname => (@hostname ||= `hostname`.chomp), :max_instances => @config.max_instances,
      :idle_instances => (@config.max_instances - @instances.size), :username => ENV['USER'] }.merge(base_params)
  end
  
  def base_params
    { :version => Testbot::VERSION, :uid => @uid }
  end
  
  def max_instances_running?
    @instances.size == @config.max_instances
  end

  def clear_completed_instances
    @instances.each_with_index do |data, index|
      @instances.delete_at(index) if data.first.join(0.25)
    end
  end

  def free_instance_number
    0.upto(@config.max_instances - 1) do |number|
      return number unless @instances.find { |instance, n, job| n == number }
    end
  end
   
  def start_ping
    Thread.new do
      while true
        begin
          Server.get("/runners/ping", :body => ping_params)
        rescue
        end
        sleep TIME_BETWEEN_PINGS
      end
    end
  end
   
end
