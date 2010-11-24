package Mediathek;
use strict;
use warnings;

BEGIN { $Class::Date::WARNINGS=0; }
use Lingua::DE::ASCII;

use WWW::Mechanize;
use File::Util;
use YAML::Any qw/LoadFile DumpFile Dump/;
use Log::Log4perl;

use XML::Simple;
use Data::Dumper;
use Class::Date qw/date/;
use DBI;
use XML::Twig;
use Memory::Usage;
use Format::Human::Bytes;

use IO::Uncompress::Unzip qw(unzip $UnzipError) ;

use Video::Flvstreamer;

sub new{
    my( $class, $args ) = @_;

    my $self=  {};

    bless $self, $class;

    my $logger = Log::Log4perl->get_logger();
    $self->{logger} = $logger;

    my $mech = WWW::Mechanize->new();
    if( $args->{proxy} ){
        $mech->proxy(['http', 'ftp'], $args->{proxy} )
    }

    if( $args->{agent} ){
        $mech->agent( $args->{agent} );
    }

    if( $args->{cookie_jar} ){
        $mech->cookie_jar( { file => $args->{cookie_jar} } );
    }


    $self->{mech} = $mech;

    foreach( qw/cookie_jar flvstreamer cache_time target_dir mu sqlite_cache_size/ ){
        if( $args->{$_} ){
            $self->{$_} = $args->{$_};
        }
    }

    # Some defaults
    if( ! $self->{mu} ){
        $self->{logger}->warn( "MU not passed to Mediathek - initialising!" );
        $self->{mu} = Memory::Usage->new();
    }

    $self->{flvstreamer} ||= 'flvstreamer';
    $self->{cache_time}  ||= 3600;
    $self->{sqlite_cache_size} ||= 80000;  # Allow sqlite to use 80MB in memory for caching
    $self->{logger}->debug( "Using flvstreamer: $self->{flvstreamer}" );
    $self->{logger}->debug( "Cache time: $self->{cache_time}" );

    if( $self->{sqlite_cache_size} !~ m/^\d*$/ ){
        die( "Invalid number for sqlite_cache_size: $self->{sqlite_cache_size}" );
    }

    my $f = File::Util->new();
    $self->{f} = $f;

    if( ! $args->{cache_dir} || ! -d $args->{cache_dir} ){
        die( "Cannot run without defining cache dir, or cache dir does not exist" );
    }
    $self->{cache_files}->{sources}   = $args->{cache_dir} . $f->SL() . 'sources.xml';
    $self->{cache_files}->{media}     = $args->{cache_dir} . $f->SL() . 'media.xml';
    $self->{cache_files}->{media_zip} = $args->{cache_dir} . $f->SL() . 'media.zip';
    $self->{cache_files}->{db}        = $args->{cache_dir} . $f->SL() . 'mediathek.db';

    my $flv = Video::Flvstreamer->new( { target_dir  => $args->{target_dir},
                                         timeout     => $args->{timeout},
                                         flvstreamer => $args->{flvstreamer},
                                         socks       => $args->{socks},
                                        } );
    $self->{flv} = $flv;


    if( ! -f $self->{cache_files}->{db} ){
        $self->init_db();
    }
    my $dbh = DBI->connect("dbi:SQLite:dbname=" . $self->{cache_files}->{db},"","");
    if( ! $dbh ){
        die( "DB could not be initialised: #!" );
    }
    # Make UTF compatible
    $dbh->{sqlite_unicode} = 1;

    # turning synchronous off makes SQLite /much/ faster!
    # It might also be responsible for race conditions where a read doesn't see a write which has just happened...
    $dbh->do( "PRAGMA synchronous=OFF" );
    $dbh->do( "PRAGMA cache_size=" . $self->{sqlite_cache_size} );

    $self->{dbh} = $dbh;
    $self->{logger}->debug( "Cache files:\n" . Dump( $self->{cache_files} ) );

    $self->{mu}->record( "New " . __PACKAGE__ . " initialised" );

    return $self;

}

sub refresh_sources{
    my( $self ) = @_;
    $self->{mu}->record( __PACKAGE__ . "->refresh_sources start" );

    my $f = File::Util->new();


    # Give some debug info about the cache file
    if( $self->{logger}->is_debug() && $self->{cache_files}->{sources} ){
        $self->{logger}->debug( "Cached sources file " . ( -f $self->{cache_files}->{sources} ? 'exists' : 'does not exist' ) );
        if( -f $self->{cache_files}->{sources} ){
            $self->{logger}->debug( "Cached sources file is " . ( time() - $self->{f}->created( $self->{cache_files}->{sources} ) ) . 's old' );
        }
    }

    if( ! $self->{cache_files}->{sources} ){
        die( "Cannot refresh sources without a cache file" );
    }

    if( ! -f $self->{cache_files}->{sources} ||
          ( time() - $self->{f}->created( $self->{cache_files}->{sources} ) > $self->{cache_time} ) ){
        $self->{logger}->debug( "Loading sources from internet" );
        $self->get_url_to_file( 'http://zdfmediathk.sourceforge.net/update.xml', $self->{cache_files}->{sources} );
    }
    $self->{logger}->debug( "Sources XML file is " . 
                              Format::Human::Bytes::base10( $self->{f}->size( $self->{cache_files}->{sources} ) ) );

    $self->{logger}->debug( "Deleting sources table in db" );
    my $sql = 'DELETE FROM sources';
    my $sth = $self->{dbh}->prepare( $sql );
    $sth->execute;

    my $t= XML::Twig->new( twig_handlers =>
                             { Server => \&source_to_db,
                           },
                          );
    $sql = 'INSERT INTO sources ( url, time, tried ) VALUES( ?, ?, 0 )';
    $sth = $self->{dbh}->prepare( $sql );
    $t->{mediathek_sth} = $sth;
    $t->{mediathek_mu} = $self->{mu};

    $self->{logger}->debug( "Parsing source XML: $self->{cache_files}->{sources}" );
    $self->{mu}->record( __PACKAGE__ . "->refresh_sources before parse xml" );
    $t->parsefile( $self->{cache_files}->{sources} );
    $self->{mu}->record( __PACKAGE__ . "->refresh_sources after parse xml" );
    $self->{logger}->debug( "Finished parsing source XML" );
    $t->purge;
    $sth->finish;
    $self->{mu}->record( __PACKAGE__ . "->refresh_sources end" );
}

sub source_to_db{
    my( $t, $section ) = @_;

    my %values;
    ###FIXME - get all children, not just by name
    foreach my $key ( qw/Download_Filme_1 Datum Zeit/ ){
        my $element = $section->first_child( $key );
        if( $element ){
            $values{$key} = $element->text();
        }
    }
    my( $day, $month, $year ) = split( /\./, $values{Datum} );
    my( $hour, $min, $sec ) = split( /:/, $values{Zeit} );
    my $date = Class::Date->new( [$year,$month,$day,$hour,$min,$sec] );
    $t->{mediathek_sth}->execute( $values{Download_Filme_1}, $date );
}

sub refresh_media{
    my( $self ) = @_;

    $self->{mu}->record( __PACKAGE__ . "->refresh_media start" );

    $self->refresh_sources();

    if( ! $self->{dbh} ){
        die( "Cannot get_media without a dbh" );
    }

    if( ! $self->{cache_files}->{media} ){
        die( "Cannot refresh media without a cache file" );
    }

    # Give some debug info about the cache file
    if( $self->{logger}->is_debug() && $self->{cache_files}->{media} ){
        $self->{logger}->debug( "Cached media file ($self->{cache_files}->{media}) " . ( -f $self->{cache_files}->{media} ? 'exists' : 'does not exist' ) );
        if( -f $self->{cache_files}->{media} ){
            $self->{logger}->debug( "Cached media file is " . ( time() - $self->{f}->created( $self->{cache_files}->{media} ) ) . 's old' );
        }
    }

    if( ! -f $self->{cache_files}->{media} ||
          ( time() - $self->{f}->created( $self->{cache_files}->{media} ) > $self->{cache_time} ) ){

        my $sql = 'SELECT id, url, time FROM sources WHERE tried==0 ORDER BY time DESC LIMIT 1';
        my $sth_select = $self->{dbh}->prepare( $sql );
        $sql = 'UPDATE sources SET tried=1 WHERE url=?';
        my $sth_update = $self->{dbh}->prepare( $sql );
        my $got_media = undef;
      MEDIA_SOURCE:
        do{
            $sth_select->execute();
            my $row = $sth_select->fetchrow_hashref();

            if( ! $row ){
                die( "No url found in sources table" );
            }

            $self->{logger}->debug( "Getting media from internet: $row->{url} ($row->{time})" );
            $self->get_url_to_file( $row->{url}, $self->{cache_files}->{media_zip} );
            $self->{logger}->debug( "Zip file is " . 
                                      Format::Human::Bytes::base10( $self->{f}->size( $self->{cache_files}->{media_zip} ) ) );

            $self->{logger}->debug( "Unzipping media..." );
            my $media_xml;
            # Unzip the file to an the XML string
            if( ! unzip( $self->{cache_files}->{media_zip} => $self->{cache_files}->{media}, Name => ".filme" ) ){
                $self->{logger}->warn( $UnzipError );
                $sth_update->execute( $row->{url} );
                next MEDIA_SOURCE;
            }
            $got_media = 1;
        }while( ! $got_media );
        $sth_select->finish();
        $sth_update->finish();
    }
    $self->{logger}->debug( "Media XML file is " .
                              Format::Human::Bytes::base10( $self->{f}->size( $self->{cache_files}->{media} ) ) );

    $self->{logger}->debug( "Deleting media tables in db" );
    $self->{dbh}->do( 'DELETE FROM channels' );
    $self->{dbh}->do( 'DELETE FROM themes' );
    $self->{dbh}->do( 'DELETE FROM map_media' );
    $self->{dbh}->do( 'DELETE FROM media' );

    my $t= XML::Twig->new( twig_handlers => { Filme => \&media_to_db, },
                          );
    # Prepare the statement handlers
    my $sths = {};
    my $sql = 'INSERT OR IGNORE INTO media ' .
      '( nr, filename, title, url, url_auth, url_hd, url_org, url_rtmp, url_theme ) '.
        'VALUES( ?, ?, ?, ?, ?, ?, ?, ?, ? )';
    $sths->{ins_media} = $self->{dbh}->prepare( $sql );

    $sql = 'INSERT OR IGNORE INTO channels ( channel ) VALUES( ? )';
    $sths->{ins_channel} = $self->{dbh}->prepare( $sql );

    $sql = 'INSERT OR IGNORE INTO themes ( channel_id, theme ) VALUES( ?, ? )';
    $sths->{ins_theme} = $self->{dbh}->prepare( $sql );

    $sql = 'INSERT OR IGNORE INTO map_media ( media_id, theme_id ) VALUES( ?, ? )';
    $sths->{ins_map_media} = $self->{dbh}->prepare( $sql );


    $sql = 'SELECT id AS channel_id FROM channels WHERE channel=?';
    $sths->{sel_channel_id} = $self->{dbh}->prepare( $sql );

    $sql = 'SELECT id AS theme_id FROM themes WHERE channel_id=? AND theme=?';
    $sths->{sel_theme_id} = $self->{dbh}->prepare( $sql );

    $sql = 'SELECT id AS media_id FROM media WHERE url=?';
    $sths->{sel_media_id} = $self->{dbh}->prepare( $sql );

    $t->{mediathek_sths} = $sths;
    $t->{mediathek_logger} = $self->{logger};
    $t->{mediathek_count_inserts} = 0;
    $t->{mediathek_mu} = $self->{mu};

    $self->{logger}->debug( "Parsing media XML: $self->{cache_files}->{media}" );
    $self->{mu}->record( __PACKAGE__ . "->refresh_media before parse xml" );
    $t->parsefile( $self->{cache_files}->{media} );
    $self->{mu}->record( __PACKAGE__ . "->refresh_media after parse xml" );
    $self->{logger}->debug( "Finished parsing media XML" );
    $t->purge;

    # Clean up all of the handlers
    foreach( keys( %$sths ) ){
        $sths->{$_}->finish;
    }

    $t->{mediathek_sths} = undef;
    $t->{mediathek_logger} = undef;
    $t->{mediathek_count_inserts} = undef;
    $t->{mediathek_mu} = undef;

    $self->{mu}->record( __PACKAGE__ . "->refresh_media end" );
    $self->{logger}->debug( __PACKAGE__ . "->refresh_media end" );
}

# <Filme><Nr>0000</Nr><Sender>3Sat</Sender><Thema>3sat.full</Thema><Titel>Mediathek-Beiträge</Titel><Url>http://wstreaming.zdf.de/3sat/veryhigh/110103_jazzbaltica2010ceu_musik.asx</Url><UrlOrg>http://wstreaming.zdf.de/3sat/300/110103_jazzbaltica2010ceu_musik.asx</UrlOrg><Datei>110103_jazzbaltica2010ceu_musik.asx</Datei><Film-alt>false</Film-alt></Filme>
sub media_to_db{
    my( $t, $section ) = @_;

    my %values;
    ###FIXME - get all children, not just by name
    foreach my $key ( qw/Datei Nr Sender Thema Titel Url UrlOrg UrlAuth UrlHD UrlRTMP UrlThema/ ){
        my $element = $section->first_child( $key );
        if( $element ){
            $values{$key} = $element->text();
        }
    }

    foreach( qw/Url Sender Thema Titel/ ){
        if( ! $values{$_} ){
            warn( "$_ not defined for entry $values{Nr}.  Skipping.\n" );
            return undef;
        }
    }

    my( $row, $sql );
    my $sths = $t->{mediathek_sths};
    $sths->{ins_channel}->execute( $values{Sender} );

    $sths->{sel_channel_id}->execute( $values{Sender} );
    $row = $sths->{sel_channel_id}->fetchrow_hashref();
    if( ! $row ){
        die( "Could not find channel_id for $values{Sender} at entry number $values{Nr}" );
    }
    my $channel_id = $row->{channel_id};

    $sths->{ins_theme}->execute( $channel_id, $values{Thema} );
    $sths->{sel_theme_id}->execute( $channel_id, $values{Thema} );
    $row = $sths->{sel_theme_id}->fetchrow_hashref();
    if( ! $row ){
        die( "Could not find themeid for Theme \"$values{Thema}\" and " .
               "Channel \"$values{Sender}\" (channel_id $channel_id) at entry number $values{Nr}" );
    }
    my $theme_id = $row->{theme_id};

    # Add the media data
    #( filename, title, url, url_auth, url_hd, url_org, url_rtmp, url_theme )
    $sths->{ins_media}->execute( $values{Nr}, $values{Datei}, $values{Titel}, $values{Url}, $values{UrlAuth},
                                 $values{UrlHD}, $values{UrlOrg}, $values{UrlRTMP}, $values{UrlThema} );
    $sths->{sel_media_id}->execute( $values{Url} );
    $row = $sths->{sel_media_id}->fetchrow_hashref();
    if( ! $row ){
        die( "Could not find media with url $values{Url}" );
    }
    my $media_id = $row->{media_id};

    # And lastly add the mapping
    $sths->{ins_map_media}->execute( $media_id, $theme_id );

    $t->{mediathek_count_inserts}++;
    if( $t->{mediathek_count_inserts} % 100 == 0 ){
        $t->{mediathek_mu}->record( "inserted $t->{mediathek_count_inserts} into media" );
    }
    $section->purge;
}

sub count_videos{
    my( $self, $args ) = @_;
    my $sql = 'SELECT COUNT( DISTINCT( m.id ) ) AS count_videos '.
      'FROM media m ' .
      'JOIN map_media mm ON m.id=mm.media_id ' .
      'JOIN themes t ON t.id=mm.theme_id '.
      'JOIN channels c ON c.id=t.channel_id';

    my( @where_sql, @where_args );
    if( $args->{channel} ){
        push( @where_sql, 'c.channel=?' );
        push( @where_args, $args->{channel} );
    }
    if( $args->{theme} ){
        push( @where_sql, 't.theme=?' );
        push( @where_args, $args->{theme} );
    }
    if( $args->{title} ){
        push( @where_sql, 'm.title=?' );
        push( @where_args, $args->{title} );
    }
    if( scalar( @where_sql ) > 0 ){
        $sql .= ' WHERE ' . join( ' AND ', @where_sql );
    }

    $self->{logger}->debug( "SQL: $sql" );
    $self->{logger}->debug( "SQL Args: " . join( ', ', @where_args ) );
    my $sth = $self->{dbh}->prepare( $sql );
    $sth->execute( @where_args );
    my $row = $sth->fetchrow_hashref();
    return $row->{count_videos};
}

sub list{
    my( $self, $args ) = @_;

    if( $args->{title} ){
        return $self->list_videos( $args );
    }elsif( $args->{theme} ){
        return $self->list_themes( $args );
    }else{
        return $self->list_channels( $args );
    }
}

sub list_videos{
    my( $self, $args ) = @_;

    my $sql = 'SELECT c.channel, t.theme, m.* '.
      'FROM media m ' .
      'JOIN map_media mm ON m.id=mm.media_id ' .
      'JOIN themes t ON t.id=mm.theme_id '.
      'JOIN channels c ON c.id=t.channel_id';

    my( @where_sql, @where_args );
    if( $args->{channel} ){
        push( @where_sql, 'c.channel=?' );
        push( @where_args, $args->{channel} );
    }
    if( $args->{theme} ){
        push( @where_sql, 't.theme=?' );
        push( @where_args, $args->{theme} );
    }
    if( $args->{title} ){
        push( @where_sql, 'm.title=?' );
        push( @where_args, $args->{title} );
    }
    if( scalar( @where_sql ) > 0 ){
        $sql .= ' WHERE ' . join( ' AND ', @where_sql );
    }

    $self->{logger}->debug( "SQL: $sql" );
    $self->{logger}->debug( "SQL Args: " . join( ', ', @where_args ) );

    my $sth = $self->{dbh}->prepare( $sql );
    $sth->execute( @where_args );
    my $row;
    my $out;
    while( $row = $sth->fetchrow_hashref() ){
        $out->{$row->{channel}}->{$row->{theme}}->{$row->{title}} = $row->{id};
    }
    return $out;
}

sub get_videos{
    my( $self, $args ) = @_;

    if( ! $self->{target_dir} ){
        die( __PACKAGE__ . " target dir not defined" );
    }

    if( ! -d $self->{target_dir} ){
        die( __PACKAGE__ . " target dir does not exist: $self->{target_dir}" );
    }

    my $sql = 'SELECT channels.channel, themes.theme, media.* FROM channels '.
      'JOIN themes ON channels.id=themes.channel_id '.
      'JOIN map_media  ON map_media.theme_id=themes.id '.
      'JOIN media ON media.id=map_media.media_id WHERE ';
    my( @sql_where, @sql_args );
    if( $args->{channel} ){
        push( @sql_where, "channels.channel=?" );
        push( @sql_args, $args->{channel} );
    }
    if( $args->{theme} ){
        push( @sql_where, "themes.theme=?" );
        push( @sql_args, $args->{theme} );
    }
    if( $args->{title} ){
        push( @sql_where, "media.title=?" );
        push( @sql_args, $args->{title} );
    }
    $sql .= join( ' AND ', @sql_where );
    $sql .= ' GROUP BY media.id';

    $self->{logger}->info( "SQL: $sql" );
    my $sth = $self->{dbh}->prepare( $sql );
    $sth->execute( @sql_args );

    my $count = 0;
    my $row;
    my %videos;

    while( $row = $sth->fetchrow_hashref ){
        $videos{ $count } = $row;
        $count++;
    }
    $self->{logger}->info( "Found $count videos matching" );

    foreach( sort( keys( %videos ) ) ){
        my $video = $videos{$_};
        my $target_dir = join( $self->{f}->SL(), ( $self->{target_dir} . $self->{f}->SL() . $video->{channel}, $video->{theme} ) );
        $self->{logger}->debug( "Target dir: $target_dir" );
        if( ! -d $target_dir ){
            if( ! $self->{f}->make_dir( $target_dir ) ){
                die( "Could not make target dir: $target_dir" );
            }
        }
        my $target_path = $target_dir . $self->{f}->SL() . $video->{title} . '.avi';
        $target_dir =~ s/\W/_/g;
        $self->{logger}->info( sprintf( "Getting %s/%s/%s", $video->{channel}, $video->{theme}, $video->{title} ) );
        $self->{flv}->get_raw( $video->{url}, $target_path );
    }
}


sub get_url_to_file{
    my( $self, $url, $filename ) = @_;
    $self->{logger}->debug( "Saving $url to $filename" );
    my $response = $self->{mech}->get( $url );
    if( ! $response->is_success ){
        die( "get failed: " . $response->status_line . "\n" );
    }

    my $write_mode = '>';
    my $binmode = 1;
    if( $filename =~ m/\.xml$/ ){
        $write_mode .= ':encoding(UTF-8)';
        $binmode = undef;
    }

    if( ! open( FH, $write_mode, $filename ) ){
        die( "Could not open file: $filename\n$!\n" );
    }
    if( $binmode ){
        binmode( FH );
    }
    print FH $response->decoded_content;
    close FH;
}

sub init_db{
    my( $self ) = @_;
    if( -f $self->{cache_files}->{db} ){
        $self->{logger}->debug( "Deleting old database" );
        unlink( $self->{cache_files}->{db} );
    }
    my $dbh = DBI->connect("dbi:SQLite:dbname=" . $self->{cache_files}->{db},"","");
    if( ! $dbh ){
        die( "Could not connect to DB during init_db: $!" );
    }
    $self->{logger}->debug( "Reading SQL file in" );

    if( ! open( FH, "<create_db.sql" ) ){
        die( "Could not open create_db.sql: $!" );
    }
    my $line;
    my $sql;
  LINE:
    while( $line = readline( FH ) ){
        if( $line =~ m/^\s*$/ || $line =~ m/^\-\-/ || $line =~ m/^\#/ ){
            next LINE;
        }
        chomp( $line );
        $sql .= $line;
    }
    close FH;

    my @commands = split( /;/, $sql );
    foreach( @commands ){
        $self->{logger}->debug( "SQL: $_\n" );
        $dbh->do( $_ );
    }
    $dbh->disconnect;
}

sub mu{
    my( $self ) = @_;
    return $self->{mu};
}

1;
