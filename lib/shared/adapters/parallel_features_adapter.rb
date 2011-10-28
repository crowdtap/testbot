require File.expand_path(File.join(File.dirname(__FILE__), "/helpers/ruby_env"))

class ParallelFeaturesAdapter
  
  def self.command(project_path, ruby_interpreter, files, test_env_number)
    cucumber_command = RubyEnv.ruby_command(project_path, :script => "rake parallel:features",
                                                          :ruby_interpreter => ruby_interpreter)
    features = files.gsub(/\.feature/,"").gsub("features/","").gsub(" ","|")
    puts "Features: #{features}"
    "rake parallel:features['#{features}']"
  end
 
  def self.test_files(dir)
    Dir["#{dir}/#{file_pattern}"]
  end
  
  def self.get_sizes(files)
    files.map { |file| File.stat(file).size }
  end

  def self.requester_port
    2230
  end
  
  def self.pluralized
    'parallel_features'
  end
  
  def self.base_path
    'features'
  end
  
  def self.name
    'Paralell Features'
  end

  def self.type
    'parallel_spec'
  end

  def self.rerunnable?
    true
  end

private

  def self.file_pattern
    '**/**/*.feature'
  end
end
