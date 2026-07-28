//
//  RecipeExtraction.swift
//  Core
//
//  Created by Nate Parrott on 5/4/25.
//
import Foundation
import Reeeed
import SwiftSoup

struct Recipe: Equatable, Codable {
    var url: URL?
    var title: String?
    var description: String?
    var steps: [String]?
    var ingredients: [String]?
    var ogImageURL: URL?
    
    var nonEmpty: Bool {
        (steps ?? []).count + (ingredients ?? []).count >= 2 && url != nil
    }
    
    var asReadableDoc: ReadableDoc? {
        guard let url else { return nil }
        //         let escapedTitle = Entities.escape(title?.byStrippingSiteNameFromPageTitle ?? "")
        var contentLines = [String]()
        // TODO: append p for description, ul for ingredients, ol for steps
        if let description {
            contentLines.append("<p>\(description.escapedForHTML)</p>")
        }
        if let ingredients {
            contentLines.append("<h3>Ingredients</h3>")
            contentLines.append("<ul>")
            for ing in ingredients {
                contentLines.append("<li>\(ing.escapedForHTML)</li>")
            }
            contentLines.append("</ul>")
        }
        if let steps {
            contentLines.append("<h3>Steps</h3>")
            contentLines.append("<ol>")
            for step in steps {
                contentLines.append("<li>\(step.escapedForHTML)</li>")
            }
            contentLines.append("</ol>")
        }
        
        return ReadableDoc(
            extracted: ExtractedContent(content: contentLines.joined(separator: "\n"), author: nil, title: title, excerpt: nil, date_published: nil),
            insertHeroImage: true,
            metadata: SiteMetadata(url: url, title: title, heroImage: ogImageURL)
        )
    }
}
         

extension String {
    var escapedForHTML: String {
        Entities.escape(self)
    }
}

extension WebContentWebKit {
    func tryToExtractRecipe() async throws -> (URL, Recipe)? {
        let js = """
        (function() {
            function extractRecipe() {
              // Try JSON-LD first
              let recipe = extractJsonLdRecipe() || extractItempropRecipe();
              if (!recipe) return {};

              // Set common props
              recipe.url = location.href;
            
              // Extract Open Graph image
              const ogImageMeta = document.querySelector('meta[property="og:image"]');
              if (ogImageMeta && ogImageMeta.content) {
                    recipe.ogImageURL = new URL(ogImageMeta.content, window.location.href).toString();
              }
             
              return recipe
            }

            function extractJsonLdRecipe() {
              try {
                // Find all JSON-LD scripts in the page
                const scripts = document.querySelectorAll('script[type="application/ld+json"]');
                
                // Check each script for recipe data
                for (const script of scripts) {
                  let data;
                  try {
                    data = JSON.parse(script.textContent);
                  } catch (e) {
                    console.log('Error parsing JSON-LD script:', e);
                    continue;
                  }
                  
                  // Handle data as array
                  if (Array.isArray(data)) {
                    for (const item of data) {
                      if (item['@type'] === 'Recipe' || (Array.isArray(item['@type']) && item['@type'].includes('Recipe'))) {
                        return {
                          title: item.name || '',
                          description: item.description || '',
                          ingredients: item.recipeIngredient || [],
                          steps: extractInstructions(item.recipeInstructions || []),
                          url: location.href
                        };
                      }
                    }
                  }
                  
                  // Handle direct recipe
                  if (data['@type'] === 'Recipe' || (Array.isArray(data['@type']) && data['@type'].includes('Recipe'))) {
                    return {
                      title: data.name || '',
                      description: data.description || '',
                      ingredients: data.recipeIngredient || [],
                      steps: extractInstructions(data.recipeInstructions || []),
                      url: location.href
                    };
                  }
                  
                  // Handle recipes in @graph
                  if (data['@graph']) {
                    const recipe = data['@graph'].find(item => 
                      item['@type'] === 'Recipe' || 
                      (Array.isArray(item['@type']) && item['@type'].includes('Recipe'))
                    );
                    
                    if (recipe) {
                      return {
                        title: recipe.name || '',
                        description: recipe.description || '',
                        ingredients: recipe.recipeIngredient || [],
                        steps: extractInstructions(recipe.recipeInstructions || [])
                      };
                    }
                  }
                }
                
                return null;
              } catch (e) {
                console.log('JSON-LD extraction failed:', e);
                return null;
              }
            }

            function extractItempropRecipe() {
              // Find recipe container
              const recipeEl = document.querySelector('[itemtype*="schema.org/Recipe"]');
              if (!recipeEl) return null;
              
              // Extract basic info
              const title = getText('[itemprop="name"]');
              const description = getText('[itemprop="description"]');
              
              // Extract ingredients
              const ingredients = getAllText('[itemprop="recipeIngredient"], [itemprop="ingredients"]');
              
              // Extract steps
              const steps = getAllText('[itemprop="recipeInstructions"]');
              
              return {
                title,
                description,
                ingredients,
                steps,
                url: location.href
              };
            }

            // Helper functions
            function getText(selector) {
              const el = document.querySelector(selector);
              return el ? el.textContent.trim() : '';
            }

            function getAllText(selector) {
              return Array.from(document.querySelectorAll(selector))
                .map(el => el.textContent.trim())
                .filter(text => text !== '');
            }

            function extractInstructions(instructions) {
              if (!instructions) return [];
              
              // Handle array of text
              if (Array.isArray(instructions)) {
                if (typeof instructions[0] === 'string') {
                  return instructions;
                }
                
                // Handle array of HowToStep objects
                if (instructions[0] && instructions[0]['@type'] === 'HowToStep') {
                  return instructions.map(step => step.text || '');
                }
                
                // Handle array of HowToSection objects
                if (instructions[0] && instructions[0]['@type'] === 'HowToSection') {
                  const allSteps = [];
                  instructions.forEach(section => {
                    if (section.itemListElement && Array.isArray(section.itemListElement)) {
                      const sectionSteps = section.itemListElement
                        .filter(step => step['@type'] === 'HowToStep')
                        .map(step => step.text || '');
                      allSteps.push(...sectionSteps);
                    }
                  });
                  return allSteps;
                }
              }
              
              // Handle string
              if (typeof instructions === 'string') {
                return [instructions];
              }
              
              return [];
            }
            
            const recipe = extractRecipe();
            return recipe;
        })();
        """
        let recipe = try await webview.evaluateJS(js, resultType: Recipe.self)
        if let url = recipe.url, recipe.nonEmpty {
            return (url, recipe)
        }
        return nil
    }
}

enum RecipeExtraction {
    static let recipeCheckExpression = """
    (function() {
      function hasRecipeData() {
        // Check for JSON-LD recipe data
        try {
          const jsonLdScripts = document.querySelectorAll('script[type="application/ld+json"]');
          for (const script of jsonLdScripts) {
            try {
              let data = JSON.parse(script.textContent);
              
              // Handle data as array
              if (Array.isArray(data)) {
                for (const item of data) {
                  if (item['@type'] === 'Recipe' || (Array.isArray(item['@type']) && item['@type'].includes('Recipe'))) {
                    const hasIngredients = Array.isArray(item.recipeIngredient) && item.recipeIngredient.length > 0;
                    const hasInstructions = item.recipeInstructions && 
                      (Array.isArray(item.recipeInstructions) || typeof item.recipeInstructions === 'string');
                    
                    if (hasIngredients && hasInstructions) return true;
                  }
                }
              }
              
              // Check direct recipe
              if (data['@type'] === 'Recipe' || (Array.isArray(data['@type']) && data['@type'].includes('Recipe'))) {
                const hasIngredients = Array.isArray(data.recipeIngredient) && data.recipeIngredient.length > 0;
                const hasInstructions = data.recipeInstructions && 
                  (Array.isArray(data.recipeInstructions) || typeof data.recipeInstructions === 'string');
                
                if (hasIngredients && hasInstructions) return true;
              }
              
              // Check @graph for recipes
              if (data['@graph']) {
                const recipe = data['@graph'].find(item => 
                  item['@type'] === 'Recipe' || 
                  (Array.isArray(item['@type']) && item['@type'].includes('Recipe'))
                );
                
                if (recipe) {
                  const hasIngredients = Array.isArray(recipe.recipeIngredient) && recipe.recipeIngredient.length > 0;
                  const hasInstructions = recipe.recipeInstructions && 
                    (Array.isArray(recipe.recipeInstructions) || typeof recipe.recipeInstructions === 'string');
                  
                  if (hasIngredients && hasInstructions) return true;
                }
              }
            } catch (e) {
              // Silently continue if JSON parsing fails
              continue;
            }
          }
          
          // Check for itemprop recipe data
          const recipeEl = document.querySelector('[itemtype*="schema.org/Recipe"]');
          if (recipeEl) {
            const ingredients = document.querySelectorAll('[itemprop="recipeIngredient"], [itemprop="ingredients"]');
            const steps = document.querySelectorAll('[itemprop="recipeInstructions"]');
            
            if (ingredients.length > 0 && steps.length > 0) return true;
          }
          
          // No valid recipe data found
          return false;
        } catch (error) {
          console.error("Error checking for recipe data:", error);
          return false;
        }
      }
      
      return hasRecipeData();
    })();
    """
}
