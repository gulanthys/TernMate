# Serialize draft writes and the terminal slot gate across workbenches.
require 'json'
require 'tempfile'

def store(path, part, slot, mode)
  raise ArgumentError unless %w[draft lock].include?(part) && slot.match?(/\A[1-9][0-9]*\z/)

  dir = File.dirname(path)
  input = STDIN.read
  draft_path = File.join(dir, "submit-draft-#{slot}.json")
  lock_path = File.join(dir, "submit-lock-#{slot}.json")
  compare = %w[draft-save draft-settle].include?(mode)
  File.open(File.join(dir, ".submit-slot-#{slot}.guard"), File::RDWR | File::CREAT, 0o600) do |guard|
    raise IOError unless guard.flock(File::LOCK_EX)
    if (part == 'draft' || compare) && File.exist?(lock_path)
      exit 3 unless compare
      puts '{"status":"locked"}'
      return
    end
    if compare
      request = JSON.parse(input)
      current = File.exist?(draft_path) ? JSON.parse(File.read(draft_path)) : nil
      if current != request['expected']
        puts JSON.generate(status: 'conflict', draft: mode == 'draft-save' ? current : nil)
        return
      end
      input = JSON.generate(request.fetch('replacement'))
    end
    Tempfile.create('.record.', dir) do |temp|
      temp.write(input)
      temp.close
      if mode == 'draft-save'
        File.rename(temp.path, path)
      else
        File.link(temp.path, path)
      end
    end
    puts(case mode
         when 'draft-save' then '{"status":"saved"}'
         when 'draft-settle' then '{"status":"settled"}'
         else 'true'
         end)
  end
rescue Errno::EEXIST
  exit 3
rescue StandardError
  # A parse exception may include private record contents.
  exit 2
end

store(*ARGV)
