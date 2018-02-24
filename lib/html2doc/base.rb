require "uuidtools"
require "asciimath"
require "image_size"
require "nokogiri"
require "xml/xslt"
require "pp"

module Html2Doc
  @xslt = XML::XSLT.new
  @xslt.xsl = File.read(File.join(File.dirname(__FILE__), "mathml2omml.xsl"))

  def self.process(result, filename, stylesheet, header_file, dir = nil,
                   asciimathdelims = nil)
    dir1 = create_dir(filename, dir)
    result = process_html(result, filename, stylesheet, header_file,
                          dir1, asciimathdelims)
    system "cp #{header_file} #{dir1}/header.html" unless header_file.nil?
    generate_filelist(filename, dir1)
    File.open("#{filename}.htm", "w") { |f| f.write(result) }
    mime_package result, filename, dir1
    rm_temp_files(filename, dir, dir1)
  end

  def self.create_dir(filename, dir)
    return dir if dir
    dir = "#{filename}_files"
    Dir.mkdir(dir) unless File.exists?(dir)
    dir
  end

  def self.process_html(result, filename, stylesheet, header_file, dir,
                        asciimathdelims)
    # docxml = Nokogiri::XML(asciimath_to_mathml(result, asciimathdelims))
    docxml = to_xhtml(asciimath_to_mathml(result, asciimathdelims))
    define_head(cleanup(docxml, dir), dir, filename, stylesheet, header_file)
    msword_fix(from_xhtml(docxml))
  end

  def self.rm_temp_files(filename, dir, dir1)
    system "rm #{filename}.htm"
    system "rm -r #{dir1}" unless dir
  end

  def self.cleanup(docxml, dir)
    image_cleanup(docxml, dir)
    mathml_to_ooml(docxml)
    footnotes(docxml)
    msonormal(docxml)
    docxml
  end

  def self.asciimath_to_mathml(doc, delims)
    return doc if delims.nil? || delims.size < 2
    doc.split(/(#{delims[0]}|#{delims[1]})/).each_slice(4).map do |a|
      a[2].nil? || a[2] = AsciiMath.parse(a[2]).to_mathml.
      gsub(/<math>/, "<math xmlns='http://www.w3.org/1998/Math/MathML'>")
      a.size > 1 ? a[0] + a[2] : a[0]
    end.join
  end

  def self.mathml_to_ooml(docxml)
    docxml.xpath("//*[local-name() = 'math']").each do |m|
      @xslt.xml = m.to_s.
        gsub(/<math>/, "<math xmlns='http://www.w3.org/1998/Math/MathML'>")
      ooml = @xslt.serve.gsub(/<\?[^>]+>\s*/, "").
        gsub(/ xmlns:[^=]+="[^"]+"/, "")
      m.swap(ooml)
    end
  end

  NOKOHEAD = <<~HERE.freeze
    <!DOCTYPE html SYSTEM
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head> <title></title> <meta charset="UTF-8" /> </head>
    <body> </body> </html>
  HERE

  def self.to_xhtml(xml)
    xml.gsub!(/<\?xml[^>]*>/, "")
    unless /<!DOCTYPE /.match? xml
      xml = '<!DOCTYPE html SYSTEM
          "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">' + xml
    end
    Nokogiri::XML.parse(xml)
  end

  DOCTYPE = <<~"DOCTYPE".freeze
    <!DOCTYPE html SYSTEM "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
  DOCTYPE

  def self.from_xhtml(xml)
    xml.to_xml.sub(%{ xmlns="http://www.w3.org/1999/xhtml"}, "").
      sub(DOCTYPE, "").
      gsub(%{ />}, "/>")
  end

  def self.msword_fix(r)
    # brain damage in MSWord parser
    r.gsub!(%r{<span style="mso-special-character:footnote"/>},
            '<span style="mso-special-character:footnote"></span>')
    r.gsub!(%r{<div style="mso-element:footnote-list"></div>},
            '<div style="mso-element:footnote-list"/>')
    r.gsub!(%r{(<a style="mso-comment-reference:[^>/]+)/>}, "\\1></a>")
    r.gsub!(%r{<link rel="File-List"}, "<link rel=File-List")
    r.gsub!(%r{<meta http-equiv="Content-Type"},
            "<meta http-equiv=Content-Type")
    r.gsub!(%r{&tab;|&amp;tab;}, '<span style="mso-tab-count:1">&#xA0; </span>')
    r
  end

  def self.image_resize(i, maxheight, maxwidth)
    size = [i["width"].to_i, i["height"].to_i]
    size = ImageSize.path(i["src"]).size if size[0].zero? && size[1].zero?
    # max height for Word document is 400, max width is 680
    if size[0] > maxheight
      size = [maxheight, (size[1] * maxheight / size[0]).ceil]
    end
    if size[1] > maxwidth
      size = [(size[0] * maxwidth / size[1]).ceil, maxwidth]
    end
    size
  end

  def self.image_cleanup(docxml, dir)
    docxml.xpath("//*[local-name() = 'img']").each do |i|
      matched = /\.(?<suffix>\S+)$/.match i["src"]
      uuid = UUIDTools::UUID.random_create.to_s
      new_full_filename = File.join(dir, "#{uuid}.#{matched[:suffix]}")
      # presupposes that the image source is local
      system "cp #{i['src']} #{new_full_filename}"
      i["width"], i["height"] = image_resize(i, 400, 680)
      i["src"] = new_full_filename
    end
    docxml
  end

  PRINT_VIEW = <<~XML.freeze
    <!--[if gte mso 9]>
    <xml>
    <w:WordDocument>
    <w:View>Print</w:View>
    <w:Zoom>100</w:Zoom>
    <w:DoNotOptimizeForBrowser/>
    </w:WordDocument>
    </xml>
    <![endif]-->
    <meta http-equiv=Content-Type content="text/html; charset=utf-8"/>
  XML

  def self.define_head1(docxml, dir)
    docxml.xpath("//*[local-name() = 'head']").each do |h|
      h.children.first.add_previous_sibling <<~XML
        #{PRINT_VIEW}
        <link rel="File-List" href="#{dir}/filelist.xml"/>
      XML
    end
  end

  def self.filename_substitute(stylesheet, header_filename, filename)
    if header_filename.nil?
      stylesheet.gsub!(/\n[^\n]*FILENAME[^\n]*i\n/, "\n")
    else
      stylesheet.gsub!(/FILENAME/, filename)
    end
    stylesheet
  end

  def self.stylesheet(filename, header_filename, fn)
    (fn.nil? || fn.empty?) &&
      fn = File.join(File.dirname(__FILE__), "wordstyle.css")
    stylesheet = File.read(fn, encoding: "UTF-8")
    stylesheet = filename_substitute(stylesheet, header_filename, filename)
    xml = Nokogiri::XML("<style/>")
    xml.children.first << Nokogiri::XML::Comment.new(xml, "\n#{stylesheet}\n")
    xml.root.to_s
  end

  def self.define_head(docxml, dir, filename, cssname, header_file)
    title = docxml.at("//*[local-name() = 'head']/*[local-name() = 'title']")
    head = docxml.at("//*[local-name() = 'head']")
    css = stylesheet(filename, header_file, cssname)
    add_stylesheet(head, title, css)
    define_head1(docxml, dir)
    namespace(docxml.root)
  end

  def self.add_stylesheet(head, title, css)
    if head.children.empty?
      head.add_child css
    elsif title.nil?
      head.children.first.add_previous_sibling css
    else
      title.add_next_sibling css
    end
  end

  def self.namespace(root)
    {
      o: "urn:schemas-microsoft-com:office:office",
      w: "urn:schemas-microsoft-com:office:word",
      m: "http://schemas.microsoft.com/office/2004/12/omml",
    }.each { |k, v| root.add_namespace_definition(k.to_s, v) }
    root.add_namespace(nil, "http://www.w3.org/TR/REC-html40")
  end

  def self.generate_filelist(filename, dir)
    File.open(File.join(dir, "filelist.xml"), "w") do |f|
      f.write %{<xml xmlns:o="urn:schemas-microsoft-com:office:office">
        <o:MainFile HRef="../#{filename}.htm"/>}
      # Dir.foreach(dir).sort_by { |x| x }  do |item|
      Dir.entries(dir).sort.each do |item|
        next if item == "." || item == ".." || /^\./.match(item)
        f.write %{  <o:File HRef="#{item}"/>\n}
      end
      f.write("</xml>\n")
    end
  end

  def self.msonormal(docxml)
    docxml.xpath("//*[local-name() = 'p'][not(self::*[@class])]").each do |p|
      p["class"] = "MsoNormal"
    end
    docxml.xpath("//*[local-name() = 'li'][not(self::*[@class])]").each do |p|
      p["class"] = "MsoNormal"
    end
  end
end
