#!/usr/bin/env ruby
require 'ox'
require 'json'
require 'zlib'
require 'rubygems/package'

def PubTatorBioC_to_PubAnnotationJSON(xml_file, mode = nil)
	mode ||= :go
	annotations_count = 0
	invalids_count = 0
	fix_count = 0
	skip_count = 0

	parsed_xml = Ox.parse(xml_file)
	parsed_xml.locate('collection/document').each do |doc|
		docid = doc.locate('id').first.text

		doc.locate('passage').each do |passage|
			denotations = []
			attributes = []

			text_node = passage.locate('text')
			text = text_node.first&.text

			offset = passage.locate('offset').first.text.to_i

			passage.locate('annotation').each do |annotation|
				annotations_count += 1

				id = annotation.attributes[:id]
				obj_id   = annotation.locate("infon[@key=identifier]").first&.text
				obj_type = annotation.locate("infon[@key=type]").first.text
				location = annotation.locate('location').first
				s_beg = location.attributes[:offset].to_i - offset
				s_end = s_beg + location.attributes[:length].to_i
				lex = annotation.locate('text').first.text

				# handling invalid annotations
				if mode != :go && text[s_beg ... s_end] != lex
					invalids_count += 1

					fixed = false
					if mode == :fix
						# invalid annotations are fixed and counted
						adjustment = get_adjustment(text, s_beg, s_end, lex)
						unless adjustment.nil?
							s_beg += adjustment
							s_end += adjustment
							fixed = true
							fix_count += 1
						end
					end

					unless fixed
						if mode == :skip
							# invalid annotations are counted and skipped
							skip_count += 1
							next
						elsif mode == :report
							# invalid annotations are reported
							warn "[#{docid}:#{id}] WARNING text mismatch (#{s_beg}, #{s_end}) : [#{text[s_beg ... s_end]}] vs [#{lex}]" if text[s_beg ... s_end] != lex
						end
					end
				end

				denotations << {id: id, span: {begin: s_beg, end: s_end}, obj: obj_type}
				attributes << {id: 'A' + id, subj: id, pred: 'resolved_to', obj: obj_id} unless obj_id.nil?
			end

			next if denotations.empty?
			raise "Invalid passage. Annotations exist but text does not exist." if text.nil?
			annotations = {sourcedb:'PubMed', sourceid: docid, text: text, denotations: denotations, attributes: attributes}
			yield annotations, annotations_count, invalids_count, fix_count, skip_count
		end
	end
end

def get_adjustment(text, s_beg, s_end, lex)
	window_size = 5
	window_size = s_beg if s_beg < window_size
	return nil unless window_size > 0

	window = text[(s_beg - window_size) ... (s_end - 1)]
	r = window&.rindex(lex)
	r.nil? ? nil : r - window_size
end


if __FILE__ == $0
	odir = 'output'
	mode = :go # the behavior for invalid annotations. Options include :report, :skip, :fix, or :go (default)

	## command line option processing
	require 'optparse'
	optparse = OptionParser.new do|opts|
		opts.banner = "Usage: pubtator-to-pubann.rb [options] PubTator_BioC_filename(s)"

		opts.on('-o', '--output directory', "specifies the output directory. (default: #{odir})") do |d|
			odir = d
			odir.sub(%r|/+|, '')
		end

		opts.on('-v', '--validate', 'tells it to validate annotations during the conversion') do
			mode = :report
		end

		opts.on('-s', '--skip', 'tells it to skip invalid annotations during the conversion') do
			mode = :skip
		end

		opts.on('-f', '--fix', 'tells it to try to fix invalid annotations during the conversion') do
			mode = :fix
		end

		opts.on('-h', '--help', 'displays this screen') do
			puts opts
			exit
		end
	end

	optparse.parse!

	if odir
		if Dir.exist?(odir)
			puts "The output will be stored in the directory, '#{odir}'."
		else
			Dir.mkdir(odir)
			puts "The output directory, '#{odir}', is created."
		end
	end

	def process_xml_content(xml_content, f, odir, mode)
		## read files
		#xml_file = File.read(f)
		puts "processing #{f}"

		total_annotations = 0
		total_invalids = 0
		total_fixed = 0
		total_skipped = 0

		filebase = File.basename(f, "XML")
		outfilename = "#{filebase}jsonl"
		outfilepath = File.join(odir, outfilename) unless odir.nil?
		File.open(outfilepath, 'w') do |outfile|
			PubTatorBioC_to_PubAnnotationJSON(xml_content, mode) do |annotations, annotations_count, invalids_count, fixed_count, skipped_count|
				outfile.write(annotations.to_json + "\n")
				total_annotations += annotations_count
				total_invalids += invalids_count
				total_fixed += fixed_count
				total_skipped += skipped_count
			end
		end

		puts "    Total annotation: #{total_annotations}"
		puts "    Invalid annotations: #{total_invalids} (#{100 * total_invalids.to_f/total_annotations}%)"
		puts "    Fixed annotations: #{total_fixed} (#{100 * total_fixed.to_f/total_invalids}%)"
		puts "    Skipped_annotations: #{total_skipped}"
	end

	ARGV.each do |f|
		if f.end_with?('.tar.gz')
		    puts "Extracting .tar.gz file: #{f}"
		    Zlib::GzipReader.open(f) do |gz|
		      Gem::Package::TarReader.new(gz) do |tar|
		        tar.each do |entry|
		          next unless entry.file? && entry.full_name =~ /\.xml$/i
		          puts "Processing file in tar: #{entry.full_name}"

            	  # Read the file content directly from the tar archive
            	  xml_content = entry.read
            	  process_xml_content(xml_content, entry.full_name, odir, mode)
        		end
      		  end
    		end
		elsif f =~ /\.xml$/i
		  # Process regular XML file from filesystem
    	  xml_content = File.read(f)
    	  process_xml_content(xml_content, f, odir, mode)
		else
    	  puts "Unsupported file type: #{f}"
		end
	end

end