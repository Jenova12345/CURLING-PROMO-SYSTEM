import { HelpCircle } from 'lucide-react';
import { Card, CardContent } from '@/components/ui/card';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from '@/components/ui/accordion';

const staffFaq = [
  {
    id: 'shift-signup',
    question: 'Jak si zapíšu směnu?',
    answer:
      'Přejděte do sekce Směny → záložka Volné směny. Zde vidíte pouze nabídky, které odpovídají vaší roli (např. Instruktor). Klikněte na tlačítko „Mám zájem".',
  },
  {
    id: 'color-labels',
    question: 'Co znamenají barevné štítky u směn?',
    answer:
      'Pokud máte více rolí (např. Instruktor i Bar), štítek vám říká, o jakou pozici se jedná (Tyrkysová = Instruktor, Oranžová = Obsluha baru).',
  },
  {
    id: 'whatsapp-join',
    question: 'Jak se dostanu do WhatsApp skupiny?',
    answer:
      'V sekci Komunikace uvidíte seznam skupin. Klikněte na tlačítko „Otevřít WhatsApp". Pokud skupinu nevidíte, požádejte správce o přidání.',
  },
  {
    id: 'cancel-shift',
    question: 'Můžu zrušit směnu?',
    answer:
      'Pokud je směna již schválená, musíte kontaktovat Jakuba nebo správce přímo. V aplikaci lze zrušit pouze žádost, která ještě čeká na schválení.',
  },
];

const adminFaq = [
  {
    id: 'create-event-roles',
    question: 'Jak vytvořit akci se specifickými rolemi?',
    answer:
      'V Kalendáři klikněte na den → Vytvořit akci. V sekci „Konfigurace týmu" použijte tlačítka + a − pro nastavení počtu lidí (např. 2× Instruktor, 1× Bar). Systém automaticky vytvoří správné směny.',
  },
  {
    id: 'approve-staff',
    question: 'Jak schvalovat brigádníky?',
    answer:
      'Jděte do Směny → Čekající na schválení. Kliknutím na „Schválit" jim směnu přidělíte napevno.',
  },
  {
    id: 'whatsapp-specific-users',
    question: 'Jak vytvořit WhatsApp skupinu pro konkrétní lidi?',
    answer:
      'V sekci Komunikace → Nová skupina. Můžete vybrat buď celé role, nebo v poli „Konkrétní osoby" vyhledat jmenovitě jednotlivé členy.',
  },
  {
    id: 'manage-members',
    question: 'Jak přidat nového člena nebo mu změnit roli?',
    answer:
      'V sekci Členové klikněte na ikonu tužky u daného uživatele. Zde můžete zaškrtnout nové role.',
  },
];

const Help = () => {
  return (
    <div className="p-4 md:p-8 max-w-3xl mx-auto space-y-6">
      <div className="flex items-center gap-3">
        <HelpCircle className="h-7 w-7 text-primary" />
        <h1 className="text-2xl md:text-3xl font-bold">Nápověda a Tutoriály</h1>
      </div>
      <p className="text-muted-foreground">
        Najděte odpovědi na nejčastější otázky o používání aplikace.
      </p>

      <Card>
        <CardContent className="pt-6">
          <Tabs defaultValue="staff">
            <TabsList className="w-full">
              <TabsTrigger value="staff" className="flex-1">
                Pro členy týmu
              </TabsTrigger>
              <TabsTrigger value="admin" className="flex-1">
                Pro správce
              </TabsTrigger>
            </TabsList>

            <TabsContent value="staff">
              <Accordion type="single" collapsible className="w-full">
                {staffFaq.map((item) => (
                  <AccordionItem key={item.id} value={item.id}>
                    <AccordionTrigger>{item.question}</AccordionTrigger>
                    <AccordionContent>
                      <p className="text-muted-foreground leading-relaxed">
                        {item.answer}
                      </p>
                    </AccordionContent>
                  </AccordionItem>
                ))}
              </Accordion>
            </TabsContent>

            <TabsContent value="admin">
              <Accordion type="single" collapsible className="w-full">
                {adminFaq.map((item) => (
                  <AccordionItem key={item.id} value={item.id}>
                    <AccordionTrigger>{item.question}</AccordionTrigger>
                    <AccordionContent>
                      <p className="text-muted-foreground leading-relaxed">
                        {item.answer}
                      </p>
                    </AccordionContent>
                  </AccordionItem>
                ))}
              </Accordion>
            </TabsContent>
          </Tabs>
        </CardContent>
      </Card>
    </div>
  );
};

export default Help;
