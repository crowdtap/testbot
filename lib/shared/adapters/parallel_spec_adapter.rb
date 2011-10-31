require File.expand_path(File.join(File.dirname(__FILE__), "/helpers/ruby_env"))

class ParallelSpecAdapter

  def self.command(project_path, ruby_interpreter, files, test_env_number)
    specs = files.gsub(/\.rb/,"").gsub(/\w*\//,"\/").gsub(" ","|")
    puts "Specs: #{specs}"
    "bundle exec rake parallel:spec['#{specs}']"
  end

  def self.test_files(dir)
    Dir["#{dir}/#{file_pattern}"]
  end

  def self.get_sizes(files)
    files.map { |file| File.stat(file).size }
  end

  def self.requester_port
    2299
  end

  def self.pluralized
    'parallel_specs'
  end

  def self.base_path
    "spec"
  end

  def self.name
    'Parallel Spec'
  end

  def self.type
    'parallel_spec'
  end

  def self.rerunnable?
    false
  end

private

  def self.file_pattern
    '**/**/*_spec.rb'
  end

end
