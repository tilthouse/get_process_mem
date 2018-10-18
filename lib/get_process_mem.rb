require 'pathname'
require 'bigdecimal'

# Cribbed from Unicorn Worker Killer, thanks!
class GetProcessMem
  KB_TO_BYTE = 1024          # 2**10   = 1024
  MB_TO_BYTE = 1_048_576     # 1024**2 = 1_048_576
  GB_TO_BYTE = 1_073_741_824 # 1024**3 = 1_073_741_824
  CONVERSION = { "kb" => KB_TO_BYTE, "mb" => MB_TO_BYTE, "gb" => GB_TO_BYTE }
  ROUND_UP   = Kernel.respond_to?(:BigDecimal) ? BigDecimal("0.5") : BigDecimal.new("0.5")
  attr_reader :pid

  RUNS_ON_WINDOWS = Gem.win_platform?

  if RUNS_ON_WINDOWS
    begin
      require 'sys/proctable'
    rescue LoadError => e
      message = "Please add `sys-proctable` to your Gemfile for windows machines\n"
      message << e.message
      raise e, message
    end
    include Sys
  end

  def initialize(pid = Process.pid)
    @status_file  = Pathname.new "/proc/#{pid}/status"
    @process_file = Pathname.new "/proc/#{pid}/smaps"
    @pid          = pid
    @linux        = @status_file.exist?
  end

  def linux?
    @linux
  end

  def bytes
    memory =   linux_status_memory if linux?
    memory ||= ps_memory
  end

  def kb(b = bytes)
    (b/coerce_to_big_decimal(KB_TO_BYTE)).to_f
  end

  def mb(b = bytes)
    (b/coerce_to_big_decimal(MB_TO_BYTE)).to_f
  end

  def gb(b = bytes)
    (b/coerce_to_big_decimal(GB_TO_BYTE)).to_f
  end

  def inspect
    b = bytes
    "#<#{self.class}:0x%08x @mb=#{ mb b } @gb=#{ gb b } @kb=#{ kb b } @bytes=#{b}>" % (object_id * 2)
  end

  # linux stores memory info in a file "/proc/#{pid}/status"
  # If it's available it uses less resources than shelling out to ps
  def linux_status_memory(file = @status_file)
    line = file.each_line.detect {|line| line.start_with? 'VmRSS'.freeze }
    return unless line
    return unless (_name, value, unit = line.split(nil)).length == 3
    CONVERSION[unit.downcase!] * value.to_i
  rescue Errno::EACCES, Errno::ENOENT
    0
  end

  # linux stores detailed memory info in a file "/proc/#{pid}/smaps"
  def linux_memory(file = @process_file)
    lines = file.each_line.select {|line| line.match(/^Rss/) }
    return if lines.empty?
    lines.reduce(0) do |sum, line|
      line.match(/(?<value>(\d*\.{0,1}\d+))\s+(?<unit>\w\w)/) do |m|
        value = coerce_to_big_decimal(m[:value]) + ROUND_UP
        unit  = m[:unit].downcase
        sum  += CONVERSION[unit] * value
      end
      sum
    end
  rescue Errno::EACCES
    0
  end

  # Pull memory from `ps` command, takes more resources and can freeze
  # in low memory situations
  def ps_memory
    if RUNS_ON_WINDOWS
      size = ProcTable.ps(pid).working_set_size
      coerce_to_big_decimal(size)
    else
      mem = `ps -o rss= -p #{pid}`
      KB_TO_BYTE * coerce_to_big_decimal(mem == "" ? 0 : mem)
    end
  end

  private

  def coerce_to_big_decimal(value)
    if Kernel.respond_to?(:BigDecimal)
      #running under Ruby 2.5 or later
      BigDecimal(value)
    else
      BigDecimal.new(value)
    end
  end

end
