#!/usr/bin/env ruby
require 'ox'
require 'json'

def PubTatorBioC_to_PubAnnotationJSON(xml_file, validate_p = false)
	pubannotation_docs = []

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
				id = annotation.attributes[:id]
				obj_id   = annotation.locate("infon[@key=identifier]").first&.text
				obj_type = annotation.locate("infon[@key=type]").first.text
				location = annotation.locate('location').first
				s_beg = location.attributes[:offset].to_i - offset
				s_end = s_beg + location.attributes[:length].to_i
				lex = annotation.locate('text').first.text

				if validate_p
					warn "[#{docid}:#{id}] WARNING text mismatch (#{s_beg}, #{s_end}) : [#{text[s_beg ... s_end]}] vs [#{lex}]" if text[s_beg ... s_end] != lex
				end

				denotations << {id: id, span: {begin: s_beg, end: s_end}, obj: obj_type}
				attributes << {id: 'A' + id, subj: id, pred: 'resolved_to', obj: obj_id} unless obj_id.nil?
			end

			next if denotations.empty?
			raise "Invalid passage. Annotations exist but text does not exist." if text.nil?
			annotations = {sourcedb:'PubMed', sourceid: docid, text: text, denotations: denotations, attributes: attributes}
			yield annotations
		end
	end
end


if __FILE__ == $0
	odir = 'output'
	validate_p = false

	## command line option processing
	require 'optparse'
	optparse = OptionParser.new do|opts|
		opts.banner = "Usage: pubtator-to-pubann.rb [options] PubTator_BioC_filename(s)"

		opts.on('-o', '--output directory', "specifies the output directory. (default: #{odir})") do |d|
			odir = d
			odir.sub(%r|/+|, '')
		end

		opts.on('-v', '--validate', 'tells it to validate annotation during the conversion') do
			validate_p = true
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

	ARGV.each do |f|
		## read files
		xml_file = File.read(f)
		puts "processing #{f}"

    filebase = File.basename(f, "XML")
		outfilename = "#{filebase}jsonl"
		outfilepath = File.join(odir, outfilename) unless odir.nil?
		File.open(outfilepath, 'w') do |outfile|
			PubTatorBioC_to_PubAnnotationJSON(xml_file, validate_p) do |annotations|
				outfile.write(annotations.to_json + "\n")
			end
		end
	end
end
