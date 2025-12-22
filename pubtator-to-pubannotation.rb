#!/usr/bin/env ruby
require 'ox'
require 'json'
require 'zlib'
require 'rubygems/package'

BUFFER_SIZE = 10
WINDOW_SIZE	= 10

def PubTatorBioC_to_PubAnnotationJSON(xml_file, option)
	annotations_count = 0
	invalids_count = 0
	fix_count = 0
	skip_count = 0

	parsed_xml = Ox.parse(xml_file)

	parsed_xml.locate('collection/document').each do |doc|
		docid = doc.locate('id').first.text
		pmc_id = nil

		doc.locate('passage').each do |passage|
			_pmc_id = passage.locate("infon[@key=article-id_pmc]").first&.text
			if _pmc_id
				pmc_id = _pmc_id
			end

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
				if text[s_beg ... s_end] != lex
					invalids_count += 1

					fixed = false
					if option[:fix_p]
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
						if option[:verbose_p]
							# invalid annotations are reported
							if s_beg < 0
								warn "[#{docid}:#{id}] WARNING invalid beginning offset : (#{s_beg}, #{s_end}) [#{lex}]"
							elsif s_end > text.length
								warn "[#{docid}:#{id}] WARNING invalid ending offset (max: #{text.length}) : (#{s_beg}, #{s_end}) [#{lex}] vs |#{text[-10 .. -1]}|"
							elsif s_beg > s_end
								warn "[#{docid}:#{id}] WARNING invalid order of beginning/ending offsets : (#{s_beg}, #{s_end}) [#{lex}]"
							elsif text[s_beg ... s_end] != lex
								w_begin = s_beg - WINDOW_SIZE
								w_end = s_end + WINDOW_SIZE
								w_begin = 0 if w_begin < 0
								w_end = text.length if w_end > text.length
								warn "[#{docid}:#{id}] WARNING text mismatch : (#{s_beg}, #{s_end}) [#{lex}] vs |#{text[w_begin ... s_beg]}[#{text[s_beg ... s_end]}]#{text[s_end ... w_end]}|"
							end
						end

						if option[:skip_p]
							# invalid annotations are counted and skipped
							skip_count += 1
							next
						end
					end
				end

				denotations << {id: id, span: {begin: s_beg, end: s_end}, obj: obj_type}
				attributes << {id: 'A' + id, subj: id, pred: 'resolved_to', obj: obj_id} unless obj_id.nil?
			end

			next if denotations.empty?
			raise "Invalid passage. Annotations exist but text does not exist." if text.nil?

			sourcedb, sourceid = if pmc_id && pmc_id == docid
				['PMC', pmc_id]
			else
				['PubMed', docid]
			end
			annotations = {sourcedb:sourcedb, sourceid: sourceid, text: text, denotations: denotations, attributes: attributes}
			yield annotations, annotations_count, invalids_count, fix_count, skip_count
		end
	end
end

def get_adjustment(text, s_beg, s_end, lex)
	return nil if lex.nil? || lex.empty?

	b_beg = s_beg - BUFFER_SIZE
	if b_beg < 0
		b_beg = 0
		b_end = [BUFFER_SIZE + lex.length, text.length].min
	else
		b_end = s_end + BUFFER_SIZE
		if b_end > text.length
			b_end = text.length
			b_beg = [b_end - lex.length - BUFFER_SIZE, 0].max
		end
	end

	b_text = text[b_beg ... b_end]
	r = b_text&.rindex(lex)
	r.nil? ? nil : r - (s_beg - b_beg)
end

def process_xml_content(xml_content, f, odir, option = {})
	## read files
	#xml_file = File.read(f)
	puts "processing #{f}"

	sum_annotations = 0
	sum_invalids = 0
	sum_fixed = 0
	sum_skipped = 0

	filebase = f.sub(/\.xml\z/i, "")
	outfilename = "#{filebase}.jsonl"
	outfilepath = File.join(odir, outfilename) unless odir.nil?
	File.open(outfilepath, 'w') do |outfile|
		PubTatorBioC_to_PubAnnotationJSON(xml_content, option) do |annotations, annotations_count, invalids_count, fixed_count, skipped_count|
			outfile.write(annotations.to_json + "\n")
			sum_annotations += annotations_count
			sum_invalids += invalids_count
			sum_fixed += fixed_count
			sum_skipped += skipped_count
		end
	rescue => e
		warn "    ERROR Something went wrong: " + e.message
	end

	rate_invalids = 100 * sum_invalids.to_f / sum_annotations
	rate_fixed = 100 * sum_fixed.to_f / sum_invalids

	puts "    All annotations: #{sum_annotations}"
	puts "    Invalid annotations: #{sum_invalids} (#{rate_invalids.round(2) }%)"
	puts "    Fixed annotations: #{sum_fixed} (#{rate_fixed.round(2)}%)" if sum_invalids > 0
	puts "    Skipped_annotations: #{sum_skipped}"

	[sum_annotations, sum_invalids, sum_fixed, sum_skipped]
end


if __FILE__ == $0
	odir = 'output'
	option = {
		fix_p: false,
		skip_p: false,
		verbose_p: false
	}

	## command line option processing
	require 'optparse'
	optparse = OptionParser.new do|opts|
		opts.banner = "Usage: pubtator-to-pubann.rb [options] PubTator_BioC_filename(s)"

		opts.on('-o', '--output directory', "specifies the output directory. (default: #{odir})") do |d|
			odir = d
			odir.sub(%r|/+|, '')
		end

		opts.on('-f', '--fix', 'tells it to try to fix invalid annotations during the conversion') do
			option[:fix_p] = true
		end

		opts.on('-s', '--skip', 'tells it to skip invalid annotations during the conversion') do
			option[:skip_p] = true
		end

		opts.on('-v', '--verbose', 'tells it to print out invalid annotations') do
			option[:verbose_p] = true
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

	total_annotations = 0
	total_invalids = 0
	total_fixed = 0
	total_skipped = 0

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
						sum_annotations, sum_invalids, sum_fixed, sum_skipped = process_xml_content(xml_content, entry.full_name, odir, option)
						total_annotations += sum_annotations
						total_invalids += sum_invalids
						total_fixed += sum_fixed
						total_skipped += sum_skipped
					end
				end
			end
		elsif f =~ /\.xml$/i
			# Process regular XML file from filesystem
			xml_content = File.read(f)
			sum_annotations, sum_invalids, sum_fixed, sum_skipped = process_xml_content(xml_content, f, odir, option)
			total_annotations += sum_annotations
			total_invalids += sum_invalids
			total_fixed += sum_fixed
			total_skipped += sum_skipped
		else
		  puts "Unsupported file type: #{f}"
		end
	end

	rate_invalids = 100 * total_invalids.to_f / total_annotations
	rate_fixed = 100 * total_fixed.to_f / total_invalids

	total_remaining_problems = total_invalids - total_fixed
	rate_remaining_problems = 100 * total_remaining_problems.to_f / total_annotations

	puts "Total ====="
	puts "    Annotations: #{total_annotations}"
	puts "    Invalid annotations: #{total_invalids} (#{rate_invalids.round(2) }%)"
	puts "    Fixed annotations: #{total_fixed} (#{rate_fixed.round(2)}%)" if total_invalids > 0
	puts "    Remaining problems: #{total_remaining_problems} (#{rate_remaining_problems.round(2)}%)"
	puts "    Skipped_annotations: #{total_skipped}"
end