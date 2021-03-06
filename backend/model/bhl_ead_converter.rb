class BHLEADConverter < EADConverter

  def self.import_types(show_hidden = false)
    [
     {
       :name => "bhl_ead_xml",
       :description => "Import BHL EAD records from an XML file"
     }
    ]
  end


  def self.instance_for(type, input_file)
    if type == "bhl_ead_xml"
      self.new(input_file)
    else
      nil
    end
  end

  def self.profile
    "Convert EAD To ArchivesSpace JSONModel records"
  end
  
  def format_content(content)
  	return content if content.nil?
    content.delete!("\n") # first we remove all linebreaks, since they're probably unintentional  
    content.gsub("<p>","").gsub("</p>","\n\n" ).gsub("<p/>","\n\n")
  		   .gsub("<lb/>", "\n\n").gsub("<lb>","\n\n").gsub("</lb>","").gsub(/\,\s?++/,"") # also remove trailing commas
  	     .strip
  end
  

  def self.configure
    super
    
# The stock EAD importer imports all extents as portion = "whole" 
# We have some partial extents that we want the importer to import as portion = "part"
 with 'physdesc' do
      portion = att('altrender') || 'whole' # We want the EAD importer to know when we're importing partial extents, which we indicator via the altrender attribute
      physdesc = Nokogiri::XML::DocumentFragment.parse(inner_xml)
      extent_number_and_type = nil
      other_extent_data = []
      make_note_too = false
      physdesc.children.each do |child|
        if child.respond_to?(:name) && child.name == 'extent'
          child_content = child.content.strip 
          if extent_number_and_type.nil? && child_content =~ /^([0-9\.]+)+\s+(.*)$/
            extent_number_and_type = {:number => $1, :extent_type => $2}
          else
            other_extent_data << child_content
          end
        else
          # there's other info here; make a note as well
          make_note_too = true unless child.text.strip.empty?
        end
      end

      # only make an extent if we got a number and type
      if extent_number_and_type
        make :extent, {
          :number => $1,
          :extent_type => $2,
          :portion => portion,
          :container_summary => other_extent_data.join('; ')
        } do |extent|
          set ancestor(:resource, :archival_object), :extents, extent
        end
      else
        make_note_too = true;
      end

      if make_note_too
        content =  physdesc.to_xml(:encoding => 'utf-8') 
        make :note_singlepart, {
          :type => 'physdesc',
          :persistent_id => att('id'),
          :content => format_content( content.sub(/<head>.*?<\/head>/, '').strip )
        } do |note|
          set ancestor(:resource, :archival_object), :notes, note
        end
      end

    end
    
# The stock ASpace EAD importer only makes "Conditions Governing Access" notes out of <accessrestrict> tags
# We want to also import our <accessrestrict> tags that have a restriction end date as a "Rights Statements"

# Let ArchivesSpace do its normal thing with accessrestrict
    %w(accessrestrict accessrestrict/legalstatus \
       accruals acqinfo altformavail appraisal arrangement \
       bioghist custodhist dimensions \
       fileplan odd otherfindaid originalsloc phystech \
       prefercite processinfo relatedmaterial scopecontent \
       separatedmaterial userestrict ).each do |note|
      with note do |node|
        content = inner_xml.tap {|xml|
          xml.sub!(/<head>.*?<\/head>/m, '')
          # xml.sub!(/<list [^>]*>.*?<\/list>/m, '')
          # xml.sub!(/<chronlist [^>]*>.*<\/chronlist>/m, '')
        }

        make :note_multipart, {
          :type => node.name,
          :persistent_id => att('id'),
          :subnotes => {
            'jsonmodel_type' => 'note_text',
            'content' => format_content( content )
          }
        } do |note|
          set ancestor(:resource, :archival_object), :notes, note
        end
      end      
    end

# Now make a Rights Statement using the content from the "Conditions Governing Access" note
# and the restriction end date from the accessrestrict/date 
with 'accessrestrict/date' do
    ancestor(:archival_object) do |ao|
        ao.notes.each do |n|
            if n['type'] == 'accessrestrict'
                n['subnotes'].each do |sn|
                make :rights_statement, {
                :rights_type => 'institutional_policy',
                :restrictions => sn['content'],
                :restriction_end_date => att('normal')
                } do |rights|
                set ancestor(:resource, :archival_object), :rights_statements, rights
                end
                end
            end
        end
    end
end
	
 with 'list' do
      next ignore if @ignore 
       
      if  ancestor(:note_multipart)
        left_overs = insert_into_subnotes 
      elsif ancestor(:note_index) #Set this to ignore because our <ref>s have <list>s
	    @ignore = true
	  else
        left_overs = nil 
        make :note_multipart, {
          :type => 'odd',
          :persistent_id => att('id'),
        } do |note|
          set ancestor(:resource, :archival_object), :notes, note
        end
      end
      
      
      # now let's make the subnote list 
      type = att('type')
      if type == 'deflist' || (type.nil? && inner_xml.match(/<deflist>/))
        make :note_definedlist do |note|
          set ancestor(:note_multipart), :subnotes, note
        end
      else
        make :note_orderedlist, {
          :enumeration => att('numeration')
        } do |note|
          set ancestor(:note_multipart), :subnotes, note
        end
      end
      
      
      # and finally put the leftovers back in the list of subnotes...
      if ( !left_overs.nil? && left_overs["content"] && left_overs["content"].length > 0 ) 
        set ancestor(:note_multipart), :subnotes, left_overs 
      end 
    
    end
	
# The stock EAD converter creates separate index items for each indexentry, 
# one for the value (persname, famname, etc) and one for the reference (ref),
# even when they are within the same indexentry and are related 
# (i.e., the persname is a correspondent, the ref is a date or a location at which 
# correspondence with that person can be found). 
# The Bentley's <indexentry>s generally look something like: 
# # <indexentry><persname>Some person</persname><ref>Some date or folder</ref></indexentry>
# # As the <persname> and the <ref> are associated with one another, 
# we want to keep them together in the same index item in ArchiveSpace. 

# First we set the stock indexentry actions to ignore to avoid running each indexentry/x and indexentry/ref multiple times.
	{
      'name' => 'name',
      'persname' => 'person',
      'famname' => 'family',
      'corpname' => 'corporate_entity',
      'subject' => 'subject',
      'function' => 'function',
      'occupation' => 'occupation',
      'genreform' => 'genre_form',
      'title' => 'title',
      'geogname' => 'geographic_name'
    }.each do |k, v|
      with "indexentry/#{k}" do |node|
        @ignore = true
		end
    end

    with 'indexentry/ref' do
        @ignore = true
    end


# This will treat each <indexentry> as one item, 
# creating an index item with a 'value' from the <persname>, <famname>, etc.
# and a 'reference_text' from the <ref>. 

with 'indexentry' do
	
  entry_type = ''
  entry_value = ''
  entry_reference = ''
 
  indexentry = Nokogiri::XML::DocumentFragment.parse(inner_xml)

  indexentry.children.each do |child|

    case child.name
      when 'name'
      entry_value << child.content
      entry_type << 'name'
      when 'persname'
      entry_value << child.content
      entry_type << 'person'	
      when 'famname'
      entry_value << child.content
      entry_type << 'family'
      when 'corpname'
      entry_value << child.content
      entry_type << 'corporate_entity'
      when 'subject'
      entry_value << child.content
      entry_type << 'subject'
      when 'function'
      entry_value << child.content
      entry_type << 'function'
      when 'occupation'
      entry_value << child.content
      entry_type << 'occupation'
      when 'genreform'
      entry_value << child.content
      entry_type << 'genre_form'
      when 'title'
      entry_value << child.content
      entry_type << 'title'
      when 'geogname'
      entry_value << child.content
      entry_type << 'geographic_name'
    end
	
    if child.name == 'ref'
    entry_reference << child.content
    end

  end
	  
	make :note_index_item, {
	  :type => entry_type,
	  :value => entry_value,
	  :reference_text => entry_reference
	  } do |item|
	set ancestor(:note_index), :items, item
	end
end
	
	

# The Bentley has many EADs with <dao> tags that lack title attributes. 
# The stock ArchivesSpace EAD Converter uses each <dao>'s title attribute as 
# the value for the imported digital object's title, which is a required property. 
# As a result, all of our EADs with <dao> tags fail when trying to import into ArchivesSpace. 
# This section of the BHL EAD Converter plugin modifies the stock ArchivesSpace EAD Converter
# by forming a string containing the digital object's parent archival object's title and date (if both exist), 
# or just its title (if only the title exists), or just it's date (if only the date exists) 
# and then using that string as the imported digital object's title. 

with 'dao' do	  

# This forms a title string using the parent archival object's title, if it exists
  daotitle = ''
  ancestor(:archival_object ) do |ao|
    if ao.title
      daotitle << ao.title
    else
      daotitle = nil
    end
  end
	
# This forms a date string using the parent archival object's date expression,
# or its begin date - end date, or just it's begin date, if any exist
  daodate = ''
  ancestor(:archival_object) do |aod|
    if aod.dates && aod.dates.length > 0
      aod.dates.each do |dl|  
        if dl['expression'].length > 0
          daodate += dl['expression']
        elsif (dl['begin'].length > 0 and dl['end'].length > 0) and (dl['begin'] != dl['end']) and not (dl['expression'].length > 0)
          daodate += "#{dl['begin']} - #{dl['end']}"
        elsif dl['begin'].length > 0 and (dl['begin'] = dl['end']) and not (dl['expression'].length > 0)
          daodate += "#{dl['begin']}"
        else
          daodate = nil
        end
      end
    end
  end
	
  title = daotitle
  date_label = daodate if daodate.length > 0

# This forms a display string using the parent archival object's title and date (if both exist),
# or just its title or date (if only one exists)
  display_string = title || ''
  display_string += ', ' if title && date_label
  display_string += date_label if date_label

  make :instance, {
    :instance_type => 'digital_object'
    } do |instance|
  set ancestor(:resource, :archival_object), :instances, instance
  end

# We'll use either the <dao> title attribute (if it exists) or our display_string (if the title attribute does not exist)
  make :digital_object, {
    :digital_object_id => SecureRandom.uuid,
    :title => att('title') || display_string,
    } do |obj|
      obj.file_versions <<  {   
      :use_statement => att('role'),
      :file_uri => att('href'),
      :xlink_actuate_attribute => att('actuate'),
      :xlink_show_attribute => att('show')
      }
    set ancestor(:instance), :digital_object, obj 
    end
  end
end

end
