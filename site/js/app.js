/* ================================================================
   Steward ACS — Site Interactions
   - Scroll-triggered reveal animations
   - Landing ↔ Documentation view switching
   - Sidebar navigation for docs
   - Copy-to-clipboard for code blocks
   - Mobile hamburger menu
   ================================================================ */

(function () {
  'use strict';

  // ================================================================
  // DOM references
  // ================================================================
  const landingView = document.getElementById('landing-view');
  const docsView = document.getElementById('docs-view');
  const navHome = document.getElementById('nav-home');
  const navDocs = document.getElementById('nav-docs');
  const heroDocs = document.getElementById('hero-docs');
  const footerDocs = document.getElementById('footer-docs');
  const docsBack = document.getElementById('docs-back');
  const hamburger = document.getElementById('hamburger');
  const navLinks = document.getElementById('nav-links');
  const docsNavLinks = document.querySelectorAll('#docs-nav a');
  const docsSections = document.querySelectorAll('.docs-content .section');
  const docsInternalLinks = document.querySelectorAll('.docs-internal-link');

  // ================================================================
  // View switching: Landing ↔ Documentation
  // ================================================================
  function showLanding() {
    landingView.classList.remove('hidden');
    docsView.classList.remove('active');
    document.body.scrollTop = 0;
    document.documentElement.scrollTop = 0;
    // Update nav active state
    document.querySelectorAll('.navbar-links a').forEach(function (a) {
      a.classList.remove('active');
    });
    closeMobileMenu();
  }

  function showDocs() {
    landingView.classList.add('hidden');
    docsView.classList.add('active');
    document.body.scrollTop = 0;
    document.documentElement.scrollTop = 0;
    closeMobileMenu();
  }

  // Attach view switching
  navHome.addEventListener('click', showLanding);
  navDocs.addEventListener('click', showDocs);
  heroDocs.addEventListener('click', showDocs);
  footerDocs.addEventListener('click', showDocs);
  docsBack.addEventListener('click', showLanding);

  // ================================================================
  // Documentation sidebar navigation
  // ================================================================
  function navigateDocs(sectionId) {
    // Update sidebar active state
    docsNavLinks.forEach(function (link) {
      link.classList.toggle('active', link.dataset.section === sectionId);
    });

    // Scroll to section
    var target = document.getElementById(sectionId);
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }

  docsNavLinks.forEach(function (link) {
    link.addEventListener('click', function (e) {
      e.preventDefault();
      navigateDocs(link.dataset.section);
    });
  });

  // Internal links within docs content (e.g., links to config section)
  docsInternalLinks.forEach(function (link) {
    link.addEventListener('click', function (e) {
      e.preventDefault();
      var sectionId = link.dataset.section;
      if (sectionId) {
        navigateDocs(sectionId);
      }
    });
  });

  // ================================================================
  // Scroll-triggered reveals (IntersectionObserver)
  // ================================================================
  var revealElements = document.querySelectorAll('.reveal, .stagger-children');

  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add('visible');
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.1, rootMargin: '0px 0px -50px 0px' }
    );

    revealElements.forEach(function (el) {
      observer.observe(el);
    });
  } else {
    // Fallback: show everything immediately
    revealElements.forEach(function (el) {
      el.classList.add('visible');
    });
  }

  // Also trigger for elements already in view on load
  setTimeout(function () {
    revealElements.forEach(function (el) {
      var rect = el.getBoundingClientRect();
      var isVisible = rect.top < window.innerHeight - 50;
      if (isVisible) {
        el.classList.add('visible');
      }
    });
  }, 100);

  // ================================================================
  // Copy-to-clipboard for code blocks
  // ================================================================
  document.querySelectorAll('.code-block-copy').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var targetId = btn.dataset.copy;
      var codeEl = document.getElementById(targetId);
      if (!codeEl) return;

      // Get text content (strips HTML tags)
      var text = codeEl.textContent || codeEl.innerText;

      // Copy to clipboard
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () {
          showCopied(btn);
        }).catch(function () {
          fallbackCopy(text, btn);
        });
      } else {
        fallbackCopy(text, btn);
      }
    });
  });

  function fallbackCopy(text, btn) {
    var textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.style.position = 'fixed';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();
    try {
      document.execCommand('copy');
      showCopied(btn);
    } catch (e) {
      // silent fail
    }
    document.body.removeChild(textarea);
  }

  function showCopied(btn) {
    var original = btn.textContent;
    btn.textContent = 'Copied!';
    btn.style.color = 'var(--color-success)';
    setTimeout(function () {
      btn.textContent = original;
      btn.style.color = '';
    }, 2000);
  }

  // ================================================================
  // Mobile hamburger menu
  // ================================================================
  function closeMobileMenu() {
    hamburger.classList.remove('active');
    hamburger.setAttribute('aria-expanded', 'false');
    navLinks.classList.remove('open');
  }

  hamburger.addEventListener('click', function () {
    var isOpen = navLinks.classList.toggle('open');
    hamburger.classList.toggle('active', isOpen);
    hamburger.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
  });

  // Close mobile menu on link click
  navLinks.querySelectorAll('a').forEach(function (link) {
    link.addEventListener('click', closeMobileMenu);
  });

  // Close mobile menu on escape
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && navLinks.classList.contains('open')) {
      closeMobileMenu();
    }
  });

  // ================================================================
  // Smooth scroll for landing page anchor links
  // ================================================================
  document.querySelectorAll('a[href^="#"]').forEach(function (anchor) {
    anchor.addEventListener('click', function (e) {
      var href = anchor.getAttribute('href');
      if (href === '#') return;
      var target = document.querySelector(href);
      if (target) {
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    });
  });

  // ================================================================
  // Active docs section tracking (on scroll)
  // ================================================================
  var docSectionObserver = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          var sectionId = entry.target.id;
          docsNavLinks.forEach(function (link) {
            link.classList.toggle('active', link.dataset.section === sectionId);
          });
        }
      });
    },
    { threshold: 0.3, rootMargin: '-80px 0px 0px 0px' }
  );

  docsSections.forEach(function (section) {
    docSectionObserver.observe(section);
  });

  // ================================================================
  // Keyboard shortcuts
  // ================================================================
  document.addEventListener('keydown', function (e) {
    // Escape already handled for mobile menu
    // 'd' key for docs, 'h' key for home (only when not typing in input)
    var tag = e.target.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;

    if (e.key === 'd' && !e.metaKey && !e.ctrlKey) {
      e.preventDefault();
      showDocs();
    }
    if (e.key === 'h' && !e.metaKey && !e.ctrlKey) {
      e.preventDefault();
      showLanding();
    }
  });

  // ================================================================
  // Initial load: show landing
  // ================================================================
  showLanding();

})();
